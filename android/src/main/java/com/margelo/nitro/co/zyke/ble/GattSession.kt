package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.os.Handler
import android.util.Log
import com.margelo.nitro.core.ArrayBuffer
import java.util.UUID

/** A characteristic, identified by its service's UUID and its own. */
internal data class CharacteristicKey(val service: UUID, val characteristic: UUID)

private const val TAG = "BleNitro"

/**
 * The GATT session of one link that is up: its operation queue, its
 * notification subscriptions, its ATT MTU and the validity of its discovered
 * database, and one class per operation. Created by [GattConnection] when the
 * link comes up and closed by its close funnel; a reconnect gets a new one,
 * so nothing of a previous link (queue, subscriptions, MTU, database)
 * survives into the next. iOS has the same layer (ios/GattSession.swift).
 *
 * Confined to the manager's executor. [GattConnection] calls the operations
 * only while the link is up (DeviceNotConnected otherwise, decided there),
 * and [LinkCallback] hands over the OS's answers only while the link is open.
 *
 * Operations (see [GattOperationQueue]): MTU, connection priority, RSSI,
 * service discovery, characteristic read and write (with and without
 * response) and CCCD writes go through one FIFO queue, one at a time
 * (BluetoothGatt refuses a second procedure while one awaits its callback).
 * Each operation checks what it needs when it starts, not when it is
 * enqueued ([resolve]), so a read queued behind a discovery sees the
 * discovered database, and a write queued behind an MTU request is checked
 * against the new MTU. An operation the OS doesn't answer in time stalls the
 * queue, and the link takes itself down (the onStall hook).
 *
 * After destroy() no GATT request reaches the device (NativeBleNitro.nitro.ts,
 * "After destroy()": every completion that fires from then on fails with
 * BluetoothManagerDestroyed, so a request that still went out would be sent
 * while its caller is told it failed). destroy() closes the manager's gate at
 * once but tears the links down later, in a task behind the OS answers
 * already posted; such an answer completes the operation in flight, and the
 * queue then starts the next one. So every operation asks the owner first
 * when it starts ([LinkOwner.isDestroying]) and fails with
 * BluetoothManagerDestroyed without issuing anything; the teardown then ends
 * the rest.
 *
 * Database generations: the hub's [NotificationHub.generation] is also the
 * generation of the discovered database. Every Service Changed ends the
 * subscriptions ([NotificationHub.endAll]), which bumps it; an operation
 * records it when it starts, and an answer that arrives in a later
 * generation belongs to a database that is gone and is not applied
 * ([RepliedOperation.answer], [CccdOperation.onWritten]).
 */
internal class GattSession(
    private val deviceId: String,
    private val gatt: BluetoothGatt,
    handler: Handler,
    /** The manager the link belongs to: asked whether destroy() was called before any operation starts. */
    private val owner: LinkOwner,
    /**
     * Called when an operation's timeout stalled the queue, before that
     * operation is reported ([GattOperationQueue]): the link takes itself
     * down through its close funnel, which [close]s this session.
     */
    onStall: (operation: GattOperation<BleError>) -> Unit,
) {
    private val queue = GattOperationQueue<SessionOperation, BleError>(HandlerTimer(handler), ::operationTimedOutError, onStall)

    /** This link's subscriptions and tracked CCCD states, and the database generation (see the class comment). */
    private val hub = NotificationHub<CharacteristicKey, ArrayBuffer, BleError>(::cancelledError)

    /**
     * Whether characteristic operations may use the discovered database: true
     * once a discovery of the current generation succeeded on this link;
     * false before, while a discovery the OS accepted runs, after a discovery
     * answered with an error, and after a Service Changed until the next
     * discovery succeeds. While false, characteristic operations fail with
     * ServicesNotDiscovered and the getters see no services.
     *
     * Why a running or failed discovery invalidates it: Android replaces its
     * service list with whatever the discovery answers, success or not, and
     * up to Android 15 empties it as soon as the discovery starts
     * (BluetoothGatt.discoverServices / onSearchComplete), so the database the
     * subscriptions were made on is gone from the OS: their characteristics
     * can't be looked up, their notifications can't be routed, and a CCCD
     * write to them would get no callback. A failed discovery therefore also
     * ends every subscription (see [DiscoveryOperation]). A discovery the OS
     * refused to start leaves the list, and this flag, as they were.
     */
    private var databaseValid = false

    /**
     * The ATT MTU in effect on this link: 23 when it comes up (Bluetooth Core
     * Specification Vol 3 Part G §5.2.1), then the value of every successful
     * onMtuChanged, whoever started the exchange: this link's MTU request,
     * the peripheral, or Android 14+, which exchanges 517 by itself on the
     * connection's first MTU request. The length limit of a write without
     * response is derived from it, so it must follow every exchange, not only
     * requestMTU's.
     */
    var mtu = GattRules.DEFAULT_ATT_MTU
        private set

    /** An MTU exchange succeeded on this link (Android 14+ disregards every later request). */
    private var mtuExchanged = false

    // Operations: the link calls these only while it is up.

    /** [requested] is already checked ([GattRules.validMtuRequest]). */
    fun requestMtu(requested: Int, reply: Reply<Double, BleError>) = queue.enqueue(MtuOperation(requested, reply))

    /** [priority] is a BluetoothGatt.CONNECTION_PRIORITY_* value. */
    fun requestConnectionPriority(priority: Int, reply: Reply<Unit, BleError>) =
        queue.enqueue(ConnectionPriorityOperation(priority, reply))

    fun readRssi(reply: Reply<Double, BleError>) = queue.enqueue(RssiOperation(reply))

    /** Android discovers the characteristics together with the services. */
    fun discoverServices(reply: Reply<Unit, BleError>) = queue.enqueue(DiscoveryOperation(reply))

    fun read(key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) = queue.enqueue(ReadOperation(key, reply))

    /** [value] is the caller's own copy (the facade copies it on the calling thread); a success reports it. */
    fun write(key: CharacteristicKey, value: ByteArray, withResponse: Boolean, reply: Reply<ArrayBuffer, BleError>) =
        queue.enqueue(WriteOperation(key, value, withResponse, reply))

    /**
     * Adds subscriber [id] to [key]'s notifications (see [NotificationHub]).
     * It receives values from now on, before the CCCD write: the peripheral
     * may notify as soon as it got the write, and those first notifications
     * must not be lost. Its own CCCD operation then settles [completion].
     */
    fun subscribe(id: Long, key: CharacteristicKey, onValue: Listener<ArrayBuffer>, completion: Reply<Unit, BleError>, onEnded: Once<BleError>?) {
        hub.add(id, key, onValue, completion, onEnded)
        queue.enqueue(CccdOperation(CccdRequest.Subscribe(id, key)))
    }

    /**
     * Ends subscription [id] when it is this link's: delivery to it stops at
     * once (a Pending completion fails with OperationCancelled), then its own
     * CCCD operation turns the CCCD off if it was the characteristic's last
     * subscriber, and completes [reply]. Called also while the link is going
     * down: the queue is closed then, and the operation, failed by the close,
     * completes [reply] without error (there is nothing left to turn off).
     * Returns false, without touching [reply], when [id] isn't a live
     * subscription of this link.
     */
    fun unsubscribe(id: Long, reply: Reply<Unit, BleError>): Boolean {
        val key = hub.remove(id) ?: return false
        queue.enqueue(CccdOperation(CccdRequest.Unsubscribe(key, reply)))
        return true
    }

    /** Whether [key] has an Active subscriber (its subscribe completed, it hasn't ended). */
    fun isSubscribed(key: CharacteristicKey): Boolean = hub.isSubscribed(key)

    // Getters of the discovered database: empty while it isn't valid.

    /** The OS's GATT client, while its discovered database is valid ([databaseValid]). */
    private val database: BluetoothGatt?
        get() = if (databaseValid) gatt else null

    /** UUIDs of the discovered services. */
    fun services(): Array<String> =
        database?.services?.map { it.uuid.toString() }?.toTypedArray() ?: emptyArray()

    /** UUIDs of the discovered characteristics of [service]; empty when it isn't discovered. */
    fun characteristics(service: UUID): Array<String> =
        database?.getService(service)?.characteristics?.map { it.uuid.toString() }?.toTypedArray() ?: emptyArray()

    /** Whether the discovered services include one of [services]. */
    fun offersAnyService(services: Collection<UUID>): Boolean {
        val database = database ?: return false
        return services.any { database.getService(it) != null }
    }

    /** The declared properties of [key]; null when the lookup fails ([lookup]). */
    fun characteristicProperties(key: CharacteristicKey): CharacteristicProperties? {
        val properties = lookup(key) { return null }.properties
        return CharacteristicProperties(
            read = (properties and GattRules.PROPERTY_READ) != 0,
            write = (properties and GattRules.PROPERTY_WRITE) != 0,
            writeWithoutResponse = (properties and GattRules.PROPERTY_WRITE_WITHOUT_RESPONSE) != 0,
            notify = (properties and GattRules.PROPERTY_NOTIFY) != 0,
            indicate = (properties and GattRules.PROPERTY_INDICATE) != 0,
        )
    }

    // Closing

    /**
     * disconnect(): the queued and running operations fail at once with
     * [error] and no new procedure starts on a link that is going down; the
     * one in flight, if any, can't be recalled, and its late answer is
     * ignored. The subscriptions stay until [close] (Active ones keep
     * receiving until the link is down).
     */
    fun closeOperations(error: BleError) = queue.close(error)

    /**
     * The link's close funnel: the operations fail with [operationError]
     * (an operation whose timeout took the link down first, with its own
     * timeout), then every subscription ends with [subscriptionError]: a
     * Pending one's completion fails, an Active one's onEnded fires. Both in
     * one method because the hub relies on it: a subscribe operation failed
     * by the queue's close leaves its subscriber to the endAll of the same
     * close ([NotificationHub.finish]).
     */
    fun close(operationError: BleError, subscriptionError: BleError) {
        try {
            queue.close(operationError)
        } finally {
            hub.endAll(subscriptionError)
        }
    }

    // Events of the link

    /**
     * Service Changed (Bluetooth Core Specification Vol 3 Part G §7.1): the
     * peripheral's GATT database changed, the discovered one is out of date
     * (BluetoothGattCallback.onServiceChanged: discoverServices must be called
     * again). Android doesn't say which services changed, so:
     * - The database is invalid: later characteristic operations fail with
     *   ServicesNotDiscovered until a discovery succeeds.
     * - Every subscription ends with ServicesNotDiscovered (its
     *   characteristic may be gone or moved), which also bumps the database
     *   generation.
     * - The operation in flight is left to complete or time out: failing it
     *   early would leave Android's busy flag set until its late answer, and
     *   start the next operation into a busy client. Its answer is dropped by
     *   the generation check.
     */
    fun servicesChanged() {
        databaseValid = false
        hub.endAll(servicesChangedError(deviceId))
    }

    // The OS's answers, from LinkCallback. An answer completes only the
    // operation in flight, and only when it is about the same OS object
    // ([current]); anything else (a late answer after a timeout, an MTU
    // exchange the peripheral started) is ignored, apart from what it tells
    // about the link (the MTU).

    fun onServicesDiscovered(status: Int) {
        current<DiscoveryOperation>(target = null)?.onDiscovered(status)
    }

    /** Records the ATT MTU of every successful exchange, then answers the MTU request in flight. */
    fun onMtuChanged(negotiated: Int, status: Int) {
        if (status == BluetoothGatt.GATT_SUCCESS) {
            mtu = negotiated
            mtuExchanged = true
        }
        current<MtuOperation>(target = null)?.onMtuChanged(negotiated, status)
    }

    fun onRssiRead(rssi: Int, status: Int) {
        current<RssiOperation>(target = null)?.onRssiRead(rssi, status)
    }

    /** [value] is the read value (used only when [status] is GATT_SUCCESS). */
    fun onCharacteristicRead(characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
        current<ReadOperation>(characteristic)?.onRead(value, status)
    }

    fun onCharacteristicWrite(characteristic: BluetoothGattCharacteristic, status: Int) {
        current<WriteOperation>(characteristic)?.onWritten(status)
    }

    fun onDescriptorWrite(descriptor: BluetoothGattDescriptor, status: Int) {
        current<CccdOperation>(descriptor)?.onWritten(status)
    }

    /**
     * A notification or indication of [characteristic]: [value] is its own
     * array. Every subscriber gets a buffer of its own (NativeBleNitro.nitro.ts,
     * subscribeToCharacteristic: each value is a buffer of its own, valid
     * after the callback returns, so one subscriber can keep or modify it
     * without affecting another), and the native copy is made only for a
     * receiving subscriber: a characteristic without one (after its last
     * unsubscribe, a Service Changed or a failed CCCD-off write, or a bonded
     * peripheral that kept its CCCD on) may keep notifying at a high rate,
     * and costs no buffer.
     */
    fun onCharacteristicChanged(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        hub.deliver(keyOf(characteristic)) { ArrayBuffer.copy(value) }
    }

    /** The operation in flight when it is a [T] waiting for an answer about [target] (by identity). */
    private inline fun <reified T : SessionOperation> current(target: Any?): T? {
        val operation = queue.current as? T ?: return null
        return if (operation.target === target) operation else null
    }

    private fun keyOf(characteristic: BluetoothGattCharacteristic) =
        CharacteristicKey(characteristic.service.uuid, characteristic.uuid)

    /**
     * Finds [key] in the discovered database, or hands [onMissing] the error
     * saying why it can't, in the order of checks of NativeBleNitro.nitro.ts
     * (section on characteristic operations):
     * - ServicesNotDiscovered: no discovery of the current database generation
     *   succeeded on this link ([databaseValid]).
     * - ServiceNotFound.
     * - CharacteristicNotFound. (CharacteristicsNotDiscovered, which iOS gives
     *   for a service whose characteristics weren't discovered, can't happen
     *   here: Android always discovers the characteristics with their
     *   services, so a service without the characteristic simply lacks it.)
     */
    private inline fun lookup(key: CharacteristicKey, onMissing: (BleError) -> Nothing): BluetoothGattCharacteristic {
        if (!databaseValid) onMissing(servicesNotDiscoveredError(deviceId))
        val service = gatt.getService(key.service) ?: onMissing(serviceNotFoundError(deviceId, key.service))
        return service.getCharacteristic(key.characteristic)
            ?: onMissing(characteristicNotFoundError(deviceId, key.service, key.characteristic))
    }

    /**
     * The one check every characteristic operation makes when it starts,
     * before anything reaches the OS: [lookup], then whether the
     * characteristic allows [access] ([GattRules.violation]: its declared
     * properties, which the OS checks only partly and otherwise reports as an
     * unexplained start failure, an ATT error or a silently dropped write
     * command; then a write's length, 512 bytes, and without response one PDU
     * of this link's ATT MTU − 3, both of which Android would otherwise
     * truncate silently or, from Android 15, throw for). A violation fails
     * with the operation's own code ([violationError]).
     */
    private inline fun resolve(key: CharacteristicKey, access: GattRules.Access, onError: (BleError) -> Nothing): BluetoothGattCharacteristic {
        val characteristic = lookup(key, onError)
        GattRules.violation(access, characteristic.properties, maxWithoutResponse = mtu - GattRules.ATT_WRITE_HEADER)
            ?.let { onError(violationError(it, key.characteristic, deviceId)) }
        return characteristic
    }

    /**
     * A procedure of this session. An exception the framework throws while
     * issuing it fails only that operation, and the queue moves on; it must
     * never escape onto the handler thread, where it would crash the process:
     * - SecurityException (missing runtime permission): BluetoothUnauthorized
     * - any other RuntimeException, e.g. the IllegalArgumentException Android
     *   15's writeCharacteristic throws for a value longer than 512 bytes
     *   ([resolve] rejects such writes before they reach the OS):
     *   OperationStartFailed, as for a procedure the OS refused
     *
     * Once destroy() was called it issues nothing and fails with
     * BluetoothManagerDestroyed (see the class comment); checked first, in
     * this one place every operation starts through.
     *
     * Every operation records the database generation when it starts; an
     * answer from a later generation refers to a database that is gone
     * ([databaseChanged]). Each operation states its timeout policy
     * ([GattOperation.settleOnTimeout], required by the queue).
     */
    private abstract inner class SessionOperation(final override val description: String) : GattOperation<BleError> {
        private var startGeneration = 0L

        /** An ATT procedure: [GattRules.ATT_TRANSACTION_TIMEOUT_MS], after which the link is taken down. */
        override val timeoutMs: Long
            get() = GattRules.ATT_TRANSACTION_TIMEOUT_MS

        /**
         * The OS object whose callback answers this operation, set once the OS
         * accepted it; null for an answer that names no object (discovery,
         * MTU, RSSI). See [current].
         */
        open val target: Any?
            get() = null

        final override fun start(): BleError? {
            if (owner.isDestroying) return destroyedError()
            startGeneration = hub.generation
            return try {
                issue()
            } catch (e: SecurityException) {
                unauthorizedError(description, e)
            } catch (e: RuntimeException) {
                Log.w(TAG, "$description was refused by Android", e)
                startThrewError(description, e)
            }
        }

        /** Issues the OS call; returns null when the OS accepted it, or the error to fail with. */
        protected abstract fun issue(): BleError?

        /** The services changed since this operation started: its answer refers to a database that is gone. */
        protected val databaseChanged: Boolean
            get() = startGeneration != hub.generation
    }

    /**
     * An operation whose outcome goes to one [reply], answered by one OS
     * callback with a GATT status ([answer]).
     */
    private abstract inner class RepliedOperation<T>(
        description: String,
        protected val reply: Reply<T, BleError>,
        /**
         * Whether the answer depends on the discovered database (a
         * characteristic's handle, or the database itself), so that one from a
         * later generation must not be applied. MTU and RSSI answers don't.
         */
        private val usesDatabase: Boolean,
    ) : SessionOperation(description) {
        override fun fail(error: BleError, cause: FailCause) = reply.fail(error)

        /**
         * Completes this operation with the OS's answer: ServicesNotDiscovered
         * when it [usesDatabase] and the services changed since it started
         * (the answer may be about another attribute now), else [value] when
         * [status] is GATT_SUCCESS, else [failCode] with the status (after
         * [answeredWithError]). Every answer goes through here, so none can
         * skip the generation check or map a status differently.
         */
        protected inline fun answer(status: Int, failCode: BleErrorCode, crossinline value: () -> T) {
            queue.complete(this) {
                when {
                    usesDatabase && databaseChanged -> {
                        Log.i(TAG, "The services of $deviceId changed while '$description' ran; its result is dropped")
                        reply.fail(servicesChangedDuringError(deviceId, description))
                    }
                    status == BluetoothGatt.GATT_SUCCESS -> reply.succeed(value())
                    else -> {
                        answeredWithError(status)
                        reply.fail(gattStatusError(failCode, description, status))
                    }
                }
            }
        }

        /** Runs before an error answer is reported (current generation only). */
        protected open fun answeredWithError(status: Int) {}
    }

    /**
     * Requests an ATT MTU of [requested] and completes with the MTU in effect.
     *
     * Android 14 (API 34) changed MTU requests (BluetoothGatt.requestMtu,
     * "MTU is set to 517 for the first GATT client requesting an MTU"): the
     * first request on a connection makes the stack exchange 517, and every
     * later request, by any client on that connection, is disregarded,
     * possibly without an onMtuChanged. Waiting 30 s for that answer would
     * then time out and take the link down, so on API 34+:
     * - when this link already saw an exchange, the request completes at once
     *   with the tracked MTU;
     * - otherwise it waits [ANDROID_14_MTU_ANSWER_MS] and then completes with
     *   the tracked MTU (23 when the exchange happened before this link saw
     *   it). This is safe: requestMtu doesn't set BluetoothGatt's busy flag, so
     *   the next operation isn't refused, and a late onMtuChanged still updates
     *   the tracked MTU.
     * Below API 34 it is an ATT procedure like the others (30 s, then the link
     * is taken down).
     */
    private inner class MtuOperation(
        private val requested: Int,
        reply: Reply<Double, BleError>,
    ) : RepliedOperation<Double>("MTU request on $deviceId", reply, usesDatabase = false) {
        override val timeoutMs: Long
            get() = if (MTU_EXCHANGED_ONCE_PER_CONNECTION) ANDROID_14_MTU_ANSWER_MS else GattRules.ATT_TRANSACTION_TIMEOUT_MS

        override fun issue(): BleError? {
            if (MTU_EXCHANGED_ONCE_PER_CONNECTION && mtuExchanged) {
                queue.complete(this) { reply.succeed(mtu.toDouble()) }
                return null
            }
            return if (gatt.requestMtu(requested)) null else startFailedError(description)
        }

        override fun settleOnTimeout(): Boolean {
            if (!MTU_EXCHANGED_ONCE_PER_CONNECTION) return false
            Log.i(
                TAG,
                "$description got no onMtuChanged within $timeoutMs ms (Android 14+ disregards MTU requests after a connection's first exchange); " +
                    "completing with the ATT MTU in effect, $mtu",
            )
            reply.succeed(mtu.toDouble())
            return true
        }

        /** Completes with the negotiated MTU, already recorded by [GattSession.onMtuChanged]. */
        fun onMtuChanged(negotiated: Int, status: Int) = answer(status, BleErrorCode.DEVICEMTUCHANGEFAILED) { negotiated.toDouble() }
    }

    /**
     * Android reports the connection parameter update through no public
     * callback, so the request completes once the OS accepted it.
     */
    private inner class ConnectionPriorityOperation(
        private val priority: Int,
        reply: Reply<Unit, BleError>,
    ) : RepliedOperation<Unit>("Connection priority request on $deviceId", reply, usesDatabase = false) {
        override fun issue(): BleError? {
            if (!gatt.requestConnectionPriority(priority)) return startFailedError(description)
            queue.complete(this) { reply.succeed(Unit) }
            return null
        }

        /** Completes inside [issue]; never in flight long enough to time out. */
        override fun settleOnTimeout() = false
    }

    private inner class RssiOperation(
        reply: Reply<Double, BleError>,
    ) : RepliedOperation<Double>("RSSI read on $deviceId", reply, usesDatabase = false) {
        override fun issue(): BleError? =
            if (gatt.readRemoteRssi()) null else startFailedError(description)

        /**
         * Not an ATT procedure, but its timeout stalls the link too: its
         * answer carries nothing that identifies the request, so after a
         * timeout a late answer could be told apart from the next request's
         * only by taking the link down.
         */
        override fun settleOnTimeout() = false

        fun onRssiRead(rssi: Int, status: Int) = answer(status, BleErrorCode.DEVICERSSIREADFAILED) { rssi.toDouble() }
    }

    /**
     * Discovers the services with their characteristics. Once Android
     * accepted it, its old service list is gone (see [databaseValid]; up to
     * Android 15 the OS also drops notifications while it runs, as it can't
     * route them to a characteristic), so:
     * - success: the database is valid again; the subscriptions go on (the
     *   peripheral's database is unchanged, only Android's objects are new,
     *   and notifications and CCCD writes address the same handles);
     * - failure: the database stays invalid, and every subscription ends with
     *   ServicesNotDiscovered + the GATT status (NativeBleNitro.nitro.ts,
     *   SubscriptionEndedCallback). Its characteristic is no longer in
     *   Android's database, so it would never get a value again, and its
     *   unsubscribe could neither look it up nor get the CCCD write's answer;
     *   ending it tells the owner now (onEnded), and the next subscribe after
     *   a successful discovery writes the CCCD again;
     * - the services changed while it ran: it fails with
     *   ServicesNotDiscovered (the Service Changed already ended the
     *   subscriptions); what it found may be the old database.
     */
    private inner class DiscoveryOperation(
        reply: Reply<Unit, BleError>,
    ) : RepliedOperation<Unit>("Service discovery on $deviceId", reply, usesDatabase = true) {
        override fun issue(): BleError? {
            if (!gatt.discoverServices()) return startFailedError(description)
            databaseValid = false
            return null
        }

        /** An ATT procedure: its timeout stalls the link. */
        override fun settleOnTimeout() = false

        override fun answeredWithError(status: Int) = hub.endAll(discoveryFailedSubscriptionsEndedError(deviceId, status))

        fun onDiscovered(status: Int) = answer(status, BleErrorCode.SERVICESDISCOVERYFAILED) { databaseValid = true }
    }

    private inner class ReadOperation(
        private val key: CharacteristicKey,
        reply: Reply<ArrayBuffer, BleError>,
    ) : RepliedOperation<ArrayBuffer>("Read of characteristic ${key.characteristic} on $deviceId", reply, usesDatabase = true) {
        private var characteristic: BluetoothGattCharacteristic? = null

        override val target: Any?
            get() = characteristic

        override fun issue(): BleError? {
            val characteristic = resolve(key, GattRules.Access.Read) { return it }
            if (!gatt.readCharacteristic(characteristic)) return startFailedError(description)
            this.characteristic = characteristic
            return null
        }

        /** An ATT procedure: its timeout stalls the link. */
        override fun settleOnTimeout() = false

        fun onRead(value: ByteArray, status: Int) = answer(status, BleErrorCode.CHARACTERISTICREADFAILED) { ArrayBuffer.copy(value) }
    }

    /**
     * A write with response (ATT Write Request) or without (Write Command). It
     * completes on onCharacteristicWrite, which for a write without response
     * means the stack accepted the packet for sending, so awaiting each write
     * paces a burst (NativeBleNitro.nitro.ts, writeCharacteristic). A success
     * reports the bytes written (WriteCharacteristicCallback's responseData:
     * an ATT write response carries no value).
     */
    private inner class WriteOperation(
        private val key: CharacteristicKey,
        private val value: ByteArray,
        private val withResponse: Boolean,
        reply: Reply<ArrayBuffer, BleError>,
    ) : RepliedOperation<ArrayBuffer>("Write of characteristic ${key.characteristic} on $deviceId", reply, usesDatabase = true) {
        private var characteristic: BluetoothGattCharacteristic? = null

        override val target: Any?
            get() = characteristic

        @Suppress("DEPRECATION")
        override fun issue(): BleError? {
            val characteristic = resolve(key, GattRules.Access.Write(value.size, withResponse)) { return it }
            val writeType = if (withResponse) {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val status = gatt.writeCharacteristic(characteristic, value, writeType)
                if (status != BluetoothStatusCodes.SUCCESS) {
                    return osRefusalError(description, status, BleErrorCode.CHARACTERISTICWRITEFAILED)
                }
            } else {
                // Before API 33 the value travels through the characteristic
                // object. This thread is its only writer, except that on API
                // 23-26 the framework stores an incoming notification of the
                // same characteristic from its binder thread (a platform race
                // no app code can close).
                characteristic.writeType = writeType
                characteristic.value = value
                if (!gatt.writeCharacteristic(characteristic)) return startFailedError(description)
            }
            this.characteristic = characteristic
            return null
        }

        /** An ATT procedure (or the stack's flow control, without response): its timeout stalls the link. */
        override fun settleOnTimeout() = false

        fun onWritten(status: Int) = answer(status, BleErrorCode.CHARACTERISTICWRITEFAILED) { ArrayBuffer.copy(value) }
    }

    /**
     * The CCCD operation of one subscribe call or one unsubscribe call
     * ([CccdRequest]). What it writes is decided by the hub when it starts
     * ([NotificationHub.plan]), from the state every operation before it
     * left; its outcome goes to its own caller only, through
     * [NotificationHub.finish], its one exit on every path.
     *
     * Android also keeps a local registration per characteristic
     * (setCharacteristicNotification) without which it drops the
     * characteristic's notifications. It must match what the subscribers
     * need, whatever the CCCD's tracked state, so every CCCD operation sets it
     * to the plan's state when it starts, write or not (it is local and
     * idempotent), and a failed enable turns it back off: a write the OS
     * refused, one that threw, and one the peripheral answered with an error.
     *
     * A characteristic without a CCCD notifies unasked: the local
     * registration is all there is, and the operation succeeds without a
     * write.
     */
    private inner class CccdOperation(
        private val request: CccdRequest<CharacteristicKey, BleError>,
    ) : SessionOperation(
        when (request) {
            is CccdRequest.Subscribe -> "Subscribing (id ${request.id}) to characteristic ${request.key.characteristic} on $deviceId"
            is CccdRequest.Unsubscribe -> "Unsubscribing from characteristic ${request.key.characteristic} on $deviceId"
        }
    ) {
        /** The CCCD whose write answer is awaited; set once the OS accepted the write. */
        private var descriptor: BluetoothGattDescriptor? = null

        override val target: Any?
            get() = descriptor

        /** The characteristic of [descriptor]. */
        private var characteristic: BluetoothGattCharacteristic? = null

        /** The plan whose write the OS accepted; the hub records that write's result. Null while nothing was written. */
        private var written: NotificationHub.CccdPlan? = null

        override fun issue(): BleError? {
            val key = request.key
            val characteristic = when (request) {
                is CccdRequest.Subscribe -> resolve(key, GattRules.Access.Notify) { return it }
                // The subscription is already ended, and turning off what its
                // subscribe turned on needs no property: only the lookup. The
                // lookup fails only when Android no longer has the database the
                // subscriptions were made on (a Service Changed, or a failed
                // discovery, both of which ended every subscription and reset
                // the tracked CCCD state): the characteristic can't be
                // addressed, its notifications reach no one, and the next
                // subscribe after a successful discovery writes the CCCD again.
                is CccdRequest.Unsubscribe -> lookup(key) { missing ->
                    Log.i(TAG, "$description: nothing to turn off (${missing.message}); the subscription is ended")
                    return completeWithoutWrite()
                }
            }
            val plan = hub.plan(request, osNotifying = null)
            val cccd = characteristic.getDescriptor(CCCD_UUID)
            // Decided before the local registration changes, so nothing below
            // can throw between enabling it and the write that may revert it.
            val value = when {
                !plan.write || cccd == null -> null
                plan.enable -> enableValue(characteristic)
                else -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
            }
            if (!gatt.setCharacteristicNotification(characteristic, plan.enable)) {
                // Not a procedure the OS refused to start but a subscription
                // Android won't deliver: the subscribe's own code (NativeBleNitro.nitro.ts,
                // subscribeToCharacteristic).
                return notificationRegistrationRefusedError(deviceId, key.characteristic, plan.enable)
            }
            if (value == null || cccd == null) return completeWithoutWrite()
            val refusal = try {
                writeDescriptor(cccd, value)
            } catch (e: RuntimeException) {
                if (plan.enable) disableLocally(characteristic)
                throw e
            }
            if (refusal == null) {
                this.characteristic = characteristic
                descriptor = cccd
                written = plan
                return null
            }
            if (plan.enable) disableLocally(characteristic)
            if (refusal.linkGone && request is CccdRequest.Unsubscribe) {
                // The stack lost the link before this link heard of it
                // (onConnectionStateChange follows): the subscription is ended
                // either way, and an unsubscribe completes without error when
                // the link goes down first (NativeBleNitro.nitro.ts,
                // unsubscribeFromCharacteristic).
                Log.i(TAG, "$description: the link is going down (${refusal.error.message}); the subscription is ended")
                return completeWithoutWrite()
            }
            return refusal.error
        }

        /** An ATT procedure: its timeout stalls the link. */
        override fun settleOnTimeout() = false

        /**
         * The queue failed it (refused start, its own timeout, or the link
         * going down); the hub decides what its caller hears from the cause.
         * A write the OS accepted but never answered may or may not have
         * reached the peripheral; the hub records that as unknown.
         */
        override fun fail(error: BleError, cause: FailCause) = hub.finish(request, written, error, cause)

        /**
         * The peripheral answered the write: a failure is CharacteristicNotifyChangeFailed
         * with the status. An answer from a later database generation is
         * reported as a success: the Service Changed already ended every
         * subscription (a subscribe's subscriber is gone, an unsubscribe's
         * subscription has nothing left to turn off), and the hub ignores the
         * write's result for the reset characteristic.
         */
        fun onWritten(status: Int) {
            queue.complete(this) {
                val plan = checkNotNull(written)
                val error = if (status == BluetoothGatt.GATT_SUCCESS) null else cccdWriteError(description, status)
                if (error != null && plan.enable) disableLocally(checkNotNull(characteristic))
                hub.finish(request, plan, if (databaseChanged) null else error, null)
            }
        }

        /** Completes from inside [issue] without a write: nothing to write, or nothing left to turn off. */
        private fun completeWithoutWrite(): BleError? {
            queue.complete(this) { hub.finish(request, null, null, null) }
            return null
        }

        /**
         * The enable value for the characteristic's mode (NativeBleNitro.nitro.ts,
         * subscribeToCharacteristic: indications only when it only indicates).
         * [resolve] admitted only a characteristic that notifies or indicates.
         */
        private fun enableValue(characteristic: BluetoothGattCharacteristic): ByteArray =
            when (GattRules.cccdSubscriptionMode(characteristic.properties)) {
                GattRules.CccdSubscriptionMode.NOTIFY -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                GattRules.CccdSubscriptionMode.INDICATE -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                GattRules.CccdSubscriptionMode.UNSUPPORTED -> error("$description: resolve() admits only a characteristic that notifies or indicates")
            }

        /** Writes the CCCD; null when the OS accepted the write. */
        @Suppress("DEPRECATION")
        private fun writeDescriptor(cccd: BluetoothGattDescriptor, value: ByteArray): CccdRefusal? {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val status = gatt.writeDescriptor(cccd, value)
                if (status == BluetoothStatusCodes.SUCCESS) return null
                return CccdRefusal(
                    osRefusalError(description, status, BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED),
                    linkGone = status == BLUETOOTH_STATUS_DEVICE_NOT_CONNECTED,
                )
            }
            cccd.value = value
            if (gatt.writeDescriptor(cccd)) return null
            // Before API 33 the refusal is a bare false, which
            // BluetoothGatt.writeDescriptor returns only when its client is no
            // longer registered with the Bluetooth service, the request didn't
            // reach it, or another procedure is outstanding. The queue runs one
            // procedure at a time and takes the link down after a timeout, so on
            // a link that is still up here it means the client is going away
            // with its link.
            return CccdRefusal(startFailedError(description), linkGone = true)
        }

        /** Turns the local registration back off after a failed enable, so Android's state matches the CCCD's. */
        private fun disableLocally(characteristic: BluetoothGattCharacteristic) {
            try {
                if (!gatt.setCharacteristicNotification(characteristic, false)) {
                    Log.w(TAG, "$description failed, and Android refused to disable its local notification registration")
                }
            } catch (e: RuntimeException) {
                Log.w(TAG, "$description failed, and disabling its local notification registration failed too", e)
            }
        }
    }

    /** The OS refused a CCCD write: [error] to report, and whether the refusal says the link is already gone. */
    private class CccdRefusal(val error: BleError, val linkGone: Boolean)

    private companion object {
        /**
         * Android 14+ makes only the first MTU exchange of a connection and
         * disregards later requests (see [MtuOperation]).
         */
        val MTU_EXCHANGED_ONCE_PER_CONNECTION = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

        /**
         * How long an API 34+ MTU request waits for onMtuChanged before it
         * completes with the tracked MTU (see [MtuOperation]). One ATT
         * request/response takes a few connection intervals; 3 s leaves room
         * for slow intervals without holding the queue for long.
         */
        const val ANDROID_14_MTU_ANSWER_MS = 3_000L

        /** Client Characteristic Configuration descriptor (Bluetooth Core Specification Vol 3 Part G §3.3.3.3). */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}

/** Runs the operation timeouts on the manager's handler thread. */
private class HandlerTimer(private val handler: Handler) : OperationTimer {
    override fun schedule(task: () -> Unit, delayMs: Long): ScheduledTask =
        Scheduled(task).also { handler.postDelayed(it, delayMs) }

    /** The posted task and its handle in one object. */
    private inner class Scheduled(private val task: () -> Unit) : Runnable, ScheduledTask {
        override fun run() = task()

        override fun cancel() = handler.removeCallbacks(this)
    }
}
