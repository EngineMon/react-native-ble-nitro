package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import android.util.Log
import com.margelo.nitro.core.ArrayBuffer
import java.util.UUID

/** A characteristic, identified by its service's UUID and its own. */
internal data class CharacteristicKey(val service: UUID, val characteristic: UUID)

/**
 * One GATT link to one device: its BluetoothGatt, its callback, its operation
 * queue and its notification subscriptions. Created and owned by
 * [BleNitroBleManager]; every method runs on the manager's handler thread.
 *
 * Threading (all state is confined to the handler thread):
 * - API 27+: connectGatt(..., TRANSPORT_LE, PHY_LE_1M_MASK, handler) makes the
 *   OS run every BluetoothGattCallback on the handler thread. There, before
 *   API 33, the framework sets characteristic.value right before it calls the
 *   callback, so the value is read inside the callback without a race; API 33+
 *   passes it as a parameter.
 * - API 23-26: connectGatt(..., TRANSPORT_LE) without a handler: callbacks run
 *   on a binder thread, which only copies the value and posts the event to the
 *   handler thread. API 26 has the handler overload, but its BluetoothGatt sets
 *   characteristic.value on the binder thread *before* posting to the handler
 *   (moved into the posted runnable in 8.1), so a following notification could
 *   overwrite the value a queued callback is about to read.
 * - Every link has its own callback object, and a closed link ignores all of
 *   its callbacks, so a late callback from an old BluetoothGatt never touches
 *   the link that replaced it.
 *
 * Connection lifecycle:
 * - Connect fails with DeviceConnectionFailed + the GATT status when the link
 *   goes down before it was ever up (e.g. 133), with DeviceDisconnected + the
 *   status when it drops while the GATT cache refresh runs, with
 *   OperationTimedOut after the caller's timeout, and with OperationCancelled
 *   when disconnect() cancels it. Every failure closes the BluetoothGatt.
 * - ConnectOptions.refreshGatt: BluetoothGatt.refresh() is the first queued
 *   operation once the link is up, and connect completes after it.
 * - The disconnect event fires once, only for a link whose connect succeeded:
 *   interrupted = false with no error after disconnect() or destroy(), true
 *   with BleError(DeviceDisconnected, nativeStatus = GATT status) otherwise.
 * - disconnect() completes once the OS reports the link down, or after
 *   [DISCONNECT_TIMEOUT_MS] without that report (the client is closed then).
 * - Whenever the link closes, every pending callback completes: the pending
 *   connect, every queued operation (DeviceDisconnected, or
 *   BluetoothManagerDestroyed on destroy), pending disconnects.
 *
 * Operations (see [GattOperationQueue]): GATT cache refresh, MTU, service
 * discovery, characteristic read and write (with and without response), CCCD
 * writes, RSSI and connection priority all go through one FIFO queue, one at a
 * time. Characteristics are looked up when their operation starts, so a read
 * queued behind a discovery sees the discovered database.
 */
internal class GattConnection(
    val deviceId: String,
    private val device: BluetoothDevice,
    private val handler: Handler,
    private val refreshGatt: Boolean,
    connectCallback: (error: BleError?) -> Unit,
    /** This link's disconnect event; connect() on the connected device replaces it. */
    var disconnectCallback: ((deviceId: String, interrupted: Boolean, error: BleError?) -> Unit)?,
    /** Called once when the link closes, before any pending callback of it completes. */
    private val onClosed: (GattConnection) -> Unit,
) {
    private enum class State {
        /** connectGatt was called; the link is not up yet. */
        CONNECTING,

        /** The link is up (connect may still wait for the GATT cache refresh). */
        CONNECTED,

        /** disconnect() was called on the up link; waiting for the OS to report it down. */
        DISCONNECTING,

        /** The BluetoothGatt is closed; everything of this link is ignored. */
        CLOSED,
    }

    /** What the pending callbacks of a closing link get. */
    private class Closing(
        /** A connect that is still pending. */
        val connectError: BleError,
        /** Every queued or running operation. */
        val operationError: BleError,
        /** Pending disconnect() calls; null completes them without error. */
        val disconnectResult: BleError?,
        /** The disconnect event's interrupted flag. */
        val interrupted: Boolean,
        /** The disconnect event's error when interrupted. */
        val linkError: BleError?,
    )

    /** A notification subscription; [active] once its CCCD write succeeded. */
    private class Subscription(val onValue: (data: ArrayBuffer) -> Unit) {
        var active = false
    }

    private var state = State.CONNECTING
    private var gatt: BluetoothGatt? = null
    private var pendingConnect: ((error: BleError?) -> Unit)? = connectCallback
    private var connectSucceeded = false
    private var connectTimeoutMs = 0L
    private val pendingDisconnects = ArrayList<(error: BleError?) -> Unit>()
    private val queue = GattOperationQueue(HandlerTimer(handler), OPERATION_TIMEOUT_MS)
    private val subscriptions = HashMap<CharacteristicKey, Subscription>()

    private val connectTimeout = Runnable {
        val timedOut = bleError(BleErrorCode.OPERATIONTIMEDOUT, "Connection to $deviceId timed out after $connectTimeoutMs ms")
        close(Closing(timedOut, timedOut, null, interrupted = false, linkError = null), disconnectFirst = true)
    }

    private val disconnectTimeout = Runnable {
        Log.w(TAG, "$deviceId reported no disconnection within $DISCONNECT_TIMEOUT_MS ms of disconnect(); closing its GATT client")
        finishDisconnect()
    }

    /** A connect of this link is still pending. */
    val isConnecting: Boolean
        get() = pendingConnect != null

    /** The link is up and its connect succeeded. */
    val isConnected: Boolean
        get() = state == State.CONNECTED && pendingConnect == null

    /**
     * Starts connecting. [timeoutMs] null leaves the timeout to the OS (about
     * 30 s with autoConnect false, none with autoConnect true).
     */
    fun open(context: Context, autoConnect: Boolean, timeoutMs: Long?) {
        val opened = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                device.connectGatt(context, autoConnect, LinkCallback(), BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, handler)
            } else {
                device.connectGatt(context, autoConnect, LinkCallback(), BluetoothDevice.TRANSPORT_LE)
            }
        } catch (e: SecurityException) {
            val unauthorized = unauthorizedError("Connecting to $deviceId", e)
            close(Closing(unauthorized, unauthorized, null, interrupted = false, linkError = null), disconnectFirst = false)
            return
        }
        if (opened == null) {
            val failed = bleError(BleErrorCode.DEVICECONNECTIONFAILED, "Android could not create a GATT client for $deviceId")
            close(Closing(failed, failed, null, interrupted = false, linkError = null), disconnectFirst = false)
            return
        }
        gatt = opened
        if (timeoutMs != null) {
            connectTimeoutMs = timeoutMs
            handler.postDelayed(connectTimeout, timeoutMs)
        }
    }

    /**
     * Takes the link down. A connect that is still pending fails with
     * OperationCancelled; [callback] completes once the link is down.
     */
    fun disconnect(callback: (error: BleError?) -> Unit) {
        when (state) {
            State.CONNECTING -> {
                // The link never came up: there is nothing to tear down but the
                // pending connect, which Android may never report as ended.
                pendingDisconnects.add(callback)
                val cancelled = cancelledError()
                close(Closing(cancelled, cancelled, null, interrupted = false, linkError = null), disconnectFirst = true)
            }
            State.CONNECTED -> {
                try {
                    openGatt().disconnect()
                } catch (e: SecurityException) {
                    callback(unauthorizedError("Disconnecting from $deviceId", e))
                    return
                }
                state = State.DISCONNECTING
                pendingDisconnects.add(callback)
                pendingConnect?.let { connect ->
                    // The link came up but connect still waited for the GATT cache refresh.
                    handler.removeCallbacks(connectTimeout)
                    pendingConnect = null
                    connect(cancelledError())
                }
                // No new procedure on a link that is going down; the one in flight,
                // if any, can't be recalled, and its late callback is ignored.
                queue.failAll(bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId is disconnecting"))
                handler.postDelayed(disconnectTimeout, DISCONNECT_TIMEOUT_MS)
            }
            State.DISCONNECTING -> pendingDisconnects.add(callback)
            State.CLOSED -> callback(notConnectedError(deviceId))
        }
    }

    /**
     * Ends a disconnect() that still waits for the OS to report the link down:
     * closes the client now (disconnect fallback, or a new connect to the device).
     */
    fun finishDisconnect() {
        val down = bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId was disconnected")
        close(Closing(down, down, null, interrupted = false, linkError = null), disconnectFirst = false)
    }

    /** Bluetooth is turning off: the link is lost. */
    fun onBluetoothOff() {
        val lost = bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId disconnected: Bluetooth turned off")
        close(
            Closing(poweredOffError("connect to $deviceId"), lost, null, interrupted = state != State.DISCONNECTING, linkError = lost),
            disconnectFirst = true,
        )
    }

    /** The manager is destroyed: closes the link, everything pending fails with BluetoothManagerDestroyed. */
    fun destroy() {
        val destroyed = destroyedError()
        close(Closing(destroyed, destroyed, destroyed, interrupted = false, linkError = null), disconnectFirst = true)
    }

    fun requestMtu(mtu: Int, callback: (error: BleError?, mtu: Double?) -> Unit) =
        enqueue(MtuOperation(mtu, callback))

    fun requestConnectionPriority(priority: Int, callback: (error: BleError?) -> Unit) =
        enqueue(ConnectionPriorityOperation(priority, callback))

    fun readRssi(callback: (error: BleError?, rssi: Double?) -> Unit) =
        enqueue(RssiOperation(callback))

    /** Android discovers the characteristics together with the services. */
    fun discoverServices(callback: (error: BleError?) -> Unit) =
        enqueue(DiscoveryOperation(callback))

    fun read(key: CharacteristicKey, callback: (error: BleError?, data: ArrayBuffer?) -> Unit) =
        enqueue(ReadOperation(key, callback))

    fun write(key: CharacteristicKey, value: ByteArray, withResponse: Boolean, callback: (error: BleError?, responseData: ArrayBuffer?) -> Unit) =
        enqueue(WriteOperation(key, value, withResponse, callback))

    fun subscribe(key: CharacteristicKey, onValue: (data: ArrayBuffer) -> Unit, callback: (error: BleError?) -> Unit) =
        enqueue(EnableNotificationsOperation(key, onValue, callback))

    fun unsubscribe(key: CharacteristicKey, callback: (error: BleError?) -> Unit) =
        enqueue(DisableNotificationsOperation(key, callback))

    fun isSubscribed(key: CharacteristicKey): Boolean = subscriptions[key]?.active == true

    /** UUIDs of the discovered services; empty before discovery or when not connected. */
    fun services(): Array<String> {
        if (state != State.CONNECTED) return emptyArray()
        return openGatt().services.map { it.uuid.toString() }.toTypedArray()
    }

    /** UUIDs of the discovered characteristics of [service]; empty when unknown or not connected. */
    fun characteristics(service: UUID): Array<String> {
        if (state != State.CONNECTED) return emptyArray()
        val characteristics = openGatt().getService(service)?.characteristics ?: return emptyArray()
        return characteristics.map { it.uuid.toString() }.toTypedArray()
    }

    private fun enqueue(operation: LinkOperation) {
        if (state == State.CONNECTED) queue.enqueue(operation) else operation.fail(notConnectedError(deviceId))
    }

    private fun openGatt(): BluetoothGatt = checkNotNull(gatt) { "$deviceId has no GATT client in state $state" }

    private fun cancelledError(): BleError =
        bleError(BleErrorCode.OPERATIONCANCELLED, "Connection to $deviceId was cancelled by disconnect()")

    private fun handleConnectionState(status: Int, newState: Int) {
        if (state == State.CLOSED) return
        if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
            onLinkUp()
        } else if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
            onLinkDown(status, osMayHoldLink = newState == BluetoothProfile.STATE_CONNECTED)
        }
    }

    private fun onLinkUp() {
        if (state != State.CONNECTING) return
        state = State.CONNECTED
        if (refreshGatt) queue.enqueue(RefreshOperation()) else finishConnect()
    }

    private fun finishConnect() {
        val connect = pendingConnect ?: return
        handler.removeCallbacks(connectTimeout)
        pendingConnect = null
        connectSucceeded = true
        connect(null)
    }

    private fun onLinkDown(status: Int, osMayHoldLink: Boolean) {
        val lost = bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId disconnected (GATT status $status)", status)
        val connectError = if (state == State.CONNECTING) {
            bleError(BleErrorCode.DEVICECONNECTIONFAILED, "Connection to $deviceId failed (GATT status $status)", status)
        } else {
            lost
        }
        close(
            Closing(connectError, lost, null, interrupted = state != State.DISCONNECTING, linkError = lost),
            disconnectFirst = osMayHoldLink,
        )
    }

    private fun close(closing: Closing, disconnectFirst: Boolean) {
        if (state == State.CLOSED) return
        state = State.CLOSED
        handler.removeCallbacks(connectTimeout)
        handler.removeCallbacks(disconnectTimeout)
        gatt?.let { release(it, disconnectFirst) }
        gatt = null
        onClosed(this)
        pendingConnect?.let { connect ->
            pendingConnect = null
            connect(closing.connectError)
        }
        queue.failAll(closing.operationError)
        subscriptions.clear()
        val disconnects = pendingDisconnects.toList()
        pendingDisconnects.clear()
        disconnects.forEach { it(closing.disconnectResult) }
        if (connectSucceeded) {
            disconnectCallback?.invoke(deviceId, closing.interrupted, if (closing.interrupted) closing.linkError else null)
        }
        disconnectCallback = null
    }

    /** Closes the OS client; [disconnectFirst] for a link the OS may still hold or still be opening. */
    private fun release(gatt: BluetoothGatt, disconnectFirst: Boolean) {
        try {
            if (disconnectFirst) gatt.disconnect()
            gatt.close()
        } catch (e: SecurityException) {
            // Nobody awaits the close itself; the link's pending callbacks still complete.
            Log.e(TAG, "Closing the GATT client of $deviceId failed: a Bluetooth permission is missing", e)
        }
    }

    private fun subscriptionOf(characteristic: BluetoothGattCharacteristic): Subscription? =
        subscriptions[CharacteristicKey(characteristic.service.uuid, characteristic.uuid)]

    /** Finds [key] in the discovered database, or hands [onMissing] the ble-plx error for why it can't. */
    private inline fun BluetoothGatt.findCharacteristic(
        key: CharacteristicKey,
        onMissing: (BleError) -> Nothing,
    ): BluetoothGattCharacteristic {
        val service = getService(key.service) ?: onMissing(
            if (services.isEmpty()) {
                bleError(BleErrorCode.SERVICESNOTDISCOVERED, "Services of $deviceId are not discovered")
            } else {
                bleError(BleErrorCode.SERVICENOTFOUND, "Service ${key.service} not found on $deviceId")
            }
        )
        return service.getCharacteristic(key.characteristic) ?: onMissing(
            bleError(BleErrorCode.CHARACTERISTICNOTFOUND, "Characteristic ${key.characteristic} not found in service ${key.service} on $deviceId")
        )
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray, operation: String): BleError? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt.writeDescriptor(descriptor, value)
            return if (status == BluetoothStatusCodes.SUCCESS) null else startFailedError(operation, status)
        }
        descriptor.value = value
        return if (gatt.writeDescriptor(descriptor)) null else startFailedError(operation)
    }

    /**
     * A queued procedure of this link. An exception the framework throws while
     * issuing it fails only that operation, and the queue moves on; it must never
     * escape onto the handler thread, where it would crash the process:
     * - SecurityException (missing runtime permission): BluetoothUnauthorized
     * - any other RuntimeException, e.g. the IllegalArgumentException of the API
     *   33 writeCharacteristic/writeDescriptor for a value longer than 512 bytes,
     *   or an IllegalStateException of a closing client: OperationStartFailed,
     *   as ble-plx reports a procedure the OS refused
     */
    private abstract inner class LinkOperation(final override val description: String) : GattOperation {
        final override fun start(): BleError? = try {
            issue(openGatt())
        } catch (e: SecurityException) {
            unauthorizedError(description, e)
        } catch (e: RuntimeException) {
            Log.w(TAG, "$description was refused by Android", e)
            startFailedError("$description (${e.javaClass.simpleName}: ${e.message})")
        }

        /** Issues the OS call; returns null when the OS accepted it. */
        protected abstract fun issue(gatt: BluetoothGatt): BleError?
    }

    /** An operation completed by onDescriptorWrite. */
    private interface AwaitsDescriptorWrite {
        val descriptor: BluetoothGattDescriptor?
        fun onDescriptorWritten(status: Int)
    }

    private inner class RefreshOperation : LinkOperation("GATT cache refresh of $deviceId") {
        private val settled = Runnable { queue.complete(this) { finishConnect() } }

        override fun issue(gatt: BluetoothGatt): BleError? {
            // BluetoothGatt.refresh() is hidden API. Like ble-plx's
            // RefreshGattCustomOperation: call it by reflection, go on when it is
            // unavailable or returns false, then give the stack a moment to drop
            // its cache before the next procedure.
            val refreshed = try {
                gatt.javaClass.getMethod("refresh").invoke(gatt) as Boolean
            } catch (e: ReflectiveOperationException) {
                Log.w(TAG, "BluetoothGatt.refresh() failed for $deviceId; its GATT cache may be stale", e)
                null
            }
            if (refreshed == false) Log.w(TAG, "BluetoothGatt.refresh() returned false for $deviceId; its GATT cache may be stale")
            handler.postDelayed(settled, REFRESH_SETTLE_MS)
            return null
        }

        override fun fail(error: BleError) {
            handler.removeCallbacks(settled)
            // A closing link already failed the connect; only a refresh that timed
            // out leaves it pending.
            if (pendingConnect != null) close(Closing(error, error, null, interrupted = false, linkError = null), disconnectFirst = true)
        }
    }

    private inner class MtuOperation(
        private val mtu: Int,
        private val callback: (error: BleError?, mtu: Double?) -> Unit,
    ) : LinkOperation("MTU request on $deviceId") {
        override fun issue(gatt: BluetoothGatt): BleError? =
            if (gatt.requestMtu(mtu)) null else startFailedError(description)

        override fun fail(error: BleError) = callback(error, null)

        /** Completes with the ATT MTU now in effect. */
        fun onMtuChanged(negotiated: Int, status: Int) = queue.complete(this) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                callback(null, negotiated.toDouble())
            } else {
                callback(gattStatusError(BleErrorCode.DEVICEMTUCHANGEFAILED, description, status), null)
            }
        }
    }

    private inner class ConnectionPriorityOperation(
        private val priority: Int,
        private val callback: (error: BleError?) -> Unit,
    ) : LinkOperation("Connection priority request on $deviceId") {
        // Android has no public callback for the connection parameter update, so
        // the request completes once the OS accepted it (ble-plx: after 1 ms).
        private val accepted = Runnable { queue.complete(this) { callback(null) } }

        override fun issue(gatt: BluetoothGatt): BleError? {
            if (!gatt.requestConnectionPriority(priority)) return startFailedError(description)
            handler.post(accepted)
            return null
        }

        override fun fail(error: BleError) {
            handler.removeCallbacks(accepted)
            callback(error)
        }
    }

    private inner class RssiOperation(
        private val callback: (error: BleError?, rssi: Double?) -> Unit,
    ) : LinkOperation("RSSI read on $deviceId") {
        override fun issue(gatt: BluetoothGatt): BleError? =
            if (gatt.readRemoteRssi()) null else startFailedError(description)

        override fun fail(error: BleError) = callback(error, null)

        fun onRssiRead(rssi: Int, status: Int) = queue.complete(this) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                callback(null, rssi.toDouble())
            } else {
                callback(gattStatusError(BleErrorCode.DEVICERSSIREADFAILED, description, status), null)
            }
        }
    }

    private inner class DiscoveryOperation(
        private val callback: (error: BleError?) -> Unit,
    ) : LinkOperation("Service discovery on $deviceId") {
        override fun issue(gatt: BluetoothGatt): BleError? =
            if (gatt.discoverServices()) null else startFailedError(description)

        override fun fail(error: BleError) = callback(error)

        fun onDiscovered(status: Int) = queue.complete(this) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                callback(null)
            } else {
                callback(gattStatusError(BleErrorCode.SERVICESDISCOVERYFAILED, description, status))
            }
        }
    }

    private inner class ReadOperation(
        private val key: CharacteristicKey,
        private val callback: (error: BleError?, data: ArrayBuffer?) -> Unit,
    ) : LinkOperation("Read of characteristic ${key.characteristic} on $deviceId") {
        var characteristic: BluetoothGattCharacteristic? = null
            private set

        override fun issue(gatt: BluetoothGatt): BleError? {
            val target = gatt.findCharacteristic(key) { return it }
            if (!gatt.readCharacteristic(target)) return startFailedError(description)
            characteristic = target
            return null
        }

        override fun fail(error: BleError) = callback(error, null)

        /** [value] is the read value, present when [status] is GATT_SUCCESS. */
        fun onRead(value: ArrayBuffer?, status: Int) = queue.complete(this) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                callback(null, value)
            } else {
                callback(gattStatusError(BleErrorCode.CHARACTERISTICREADFAILED, description, status), null)
            }
        }
    }

    private inner class WriteOperation(
        private val key: CharacteristicKey,
        private val value: ByteArray,
        private val withResponse: Boolean,
        private val callback: (error: BleError?, responseData: ArrayBuffer?) -> Unit,
    ) : LinkOperation("Write of characteristic ${key.characteristic} on $deviceId") {
        var characteristic: BluetoothGattCharacteristic? = null
            private set

        @Suppress("DEPRECATION")
        override fun issue(gatt: BluetoothGatt): BleError? {
            val target = gatt.findCharacteristic(key) { return it }
            val writeType = if (withResponse) {
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            } else {
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val status = gatt.writeCharacteristic(target, value, writeType)
                if (status != BluetoothStatusCodes.SUCCESS) return startFailedError(description, status)
            } else {
                // Before API 33 the value travels through the characteristic object.
                // This thread is the only writer of it, except that on API 23-26 the
                // framework stores an incoming notification of the same
                // characteristic from its binder thread (a platform race RxAndroidBle
                // shares).
                target.writeType = writeType
                target.value = value
                if (!gatt.writeCharacteristic(target)) return startFailedError(description)
            }
            characteristic = target
            return null
        }

        override fun fail(error: BleError) = callback(error, null)

        /**
         * onCharacteristicWrite: for a write without response it means the stack
         * accepted the packet for sending, so awaiting each write paces a burst.
         * Like ble-plx, a successful write reports the written bytes.
         */
        fun onWritten(status: Int) = queue.complete(this) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                callback(null, ArrayBuffer.copy(value))
            } else {
                callback(gattStatusError(BleErrorCode.CHARACTERISTICWRITEFAILED, description, status), null)
            }
        }
    }

    private inner class EnableNotificationsOperation(
        private val key: CharacteristicKey,
        private val onValue: (data: ArrayBuffer) -> Unit,
        private val callback: (error: BleError?) -> Unit,
    ) : LinkOperation("Enabling notifications of characteristic ${key.characteristic} on $deviceId"), AwaitsDescriptorWrite {
        private var cccd: BluetoothGattDescriptor? = null
        override val descriptor: BluetoothGattDescriptor?
            get() = cccd
        private var installed: Subscription? = null
        private var replaced: Subscription? = null
        private val enabledWithoutCccd = Runnable { queue.complete(this) { succeed() } }

        override fun issue(gatt: BluetoothGatt): BleError? {
            val target = gatt.findCharacteristic(key) { return it }
            val cccdValue = when (cccdSubscriptionMode(target.properties)) {
                CccdSubscriptionMode.NOTIFY -> BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                CccdSubscriptionMode.INDICATE -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                CccdSubscriptionMode.UNSUPPORTED -> return bleError(
                    BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED,
                    "Characteristic ${key.characteristic} on $deviceId supports neither notifications nor indications",
                )
            }
            if (!gatt.setCharacteristicNotification(target, true)) {
                return bleError(BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED, "Android refused to enable notifications of ${key.characteristic} on $deviceId")
            }
            // Deliver from here on: the peripheral may notify as soon as it got the
            // CCCD write. Replaces the previous subscription of the characteristic.
            val subscription = Subscription(onValue)
            replaced = subscriptions.put(key, subscription)
            installed = subscription
            val found = target.getDescriptor(CCCD_UUID)
            if (found == null) {
                // Without a CCCD the peripheral notifies unasked: enabling it locally
                // is all there is (ble-plx's COMPAT setup).
                handler.post(enabledWithoutCccd)
                return null
            }
            writeDescriptor(gatt, found, cccdValue, description)?.let { return it }
            cccd = found
            return null
        }

        override fun onDescriptorWritten(status: Int) {
            queue.complete(this) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    succeed()
                } else {
                    uninstall()
                    callback(gattStatusError(BleErrorCode.DESCRIPTORWRITEFAILED, description, status))
                }
            }
        }

        override fun fail(error: BleError) {
            handler.removeCallbacks(enabledWithoutCccd)
            uninstall()
            callback(error)
        }

        private fun succeed() {
            installed?.active = true
            callback(null)
        }

        /** Puts back the subscription this one replaced, unless a later one replaced it in turn. */
        private fun uninstall() {
            val subscription = installed ?: return
            installed = null
            if (subscriptions[key] !== subscription) return
            val previous = replaced
            if (previous == null) subscriptions.remove(key) else subscriptions[key] = previous
        }
    }

    private inner class DisableNotificationsOperation(
        private val key: CharacteristicKey,
        private val callback: (error: BleError?) -> Unit,
    ) : LinkOperation("Disabling notifications of characteristic ${key.characteristic} on $deviceId"), AwaitsDescriptorWrite {
        private var cccd: BluetoothGattDescriptor? = null
        override val descriptor: BluetoothGattDescriptor?
            get() = cccd
        private val disabledWithoutCccd = Runnable { queue.complete(this) { callback(null) } }

        override fun issue(gatt: BluetoothGatt): BleError? {
            val target = gatt.findCharacteristic(key) { return it }
            // Delivery stops here, in call order with the link's other operations.
            subscriptions.remove(key)
            if (!gatt.setCharacteristicNotification(target, false)) {
                return bleError(BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED, "Android refused to disable notifications of ${key.characteristic} on $deviceId")
            }
            val found = target.getDescriptor(CCCD_UUID)
            if (found == null) {
                handler.post(disabledWithoutCccd)
                return null
            }
            writeDescriptor(gatt, found, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE, description)?.let { return it }
            cccd = found
            return null
        }

        override fun onDescriptorWritten(status: Int) {
            queue.complete(this) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    callback(null)
                } else {
                    callback(gattStatusError(BleErrorCode.DESCRIPTORWRITEFAILED, description, status))
                }
            }
        }

        override fun fail(error: BleError) {
            handler.removeCallbacks(disabledWithoutCccd)
            callback(error)
        }
    }

    /**
     * The BluetoothGattCallback of this link (see the threading notes above).
     * Operation callbacks complete only the operation in flight, and only when
     * it targets the same characteristic/descriptor; anything else (a late
     * callback after a timeout, an MTU exchange the peripheral started) is
     * ignored.
     */
    private inner class LinkCallback : BluetoothGattCallback() {
        /** Runs [event] on the handler thread: inline where the OS already calls there (API 27+), posted from the binder thread otherwise. */
        private inline fun onHandler(crossinline event: () -> Unit) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) event() else handler.post { event() }
        }

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = onHandler {
            handleConnectionState(status, newState)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = onHandler {
            (queue.current as? DiscoveryOperation)?.onDiscovered(status)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = onHandler {
            (queue.current as? MtuOperation)?.onMtuChanged(mtu, status)
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) = onHandler {
            (queue.current as? RssiOperation)?.onRssiRead(rssi, status)
        }

        /** API 33+, on the handler thread. */
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            onRead(characteristic, if (status == BluetoothGatt.GATT_SUCCESS) ArrayBuffer.copy(value) else null, status)
        }

        /** Before API 33: the value is copied here, before it can change, then handed to the handler thread. */
        @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val value = if (status == BluetoothGatt.GATT_SUCCESS) ArrayBuffer.copy(characteristic.value ?: EMPTY_VALUE) else null
            onHandler { onRead(characteristic, value, status) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = onHandler {
            val operation = queue.current as? WriteOperation
            if (operation != null && operation.characteristic === characteristic) operation.onWritten(status)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = onHandler {
            val operation = queue.current as? AwaitsDescriptorWrite
            if (operation != null && operation.descriptor === descriptor) operation.onDescriptorWritten(status)
        }

        /** API 33+, on the handler thread: the value is this notification's own array. */
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            subscriptionOf(characteristic)?.onValue?.invoke(ArrayBuffer.copy(value))
        }

        /**
         * Before API 33 the value lives in the shared characteristic object.
         * API 27-32 call this on the handler thread right after storing it there;
         * API 23-26 on the binder thread, so it is copied before hopping.
         */
        @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                val subscription = subscriptionOf(characteristic) ?: return
                subscription.onValue(ArrayBuffer.copy(characteristic.value ?: EMPTY_VALUE))
            } else {
                val value = ArrayBuffer.copy(characteristic.value ?: EMPTY_VALUE)
                handler.post { subscriptionOf(characteristic)?.onValue?.invoke(value) }
            }
        }

        private fun onRead(characteristic: BluetoothGattCharacteristic, value: ArrayBuffer?, status: Int) {
            val operation = queue.current as? ReadOperation
            if (operation != null && operation.characteristic === characteristic) operation.onRead(value, status)
        }
    }

    private companion object {
        const val TAG = "BleNitro"

        /** Per-operation timeout: RxAndroidBle's DEFAULT_OPERATION_TIMEOUT, so ble-plx timing carries over. */
        const val OPERATION_TIMEOUT_MS = 30_000L

        /**
         * How long disconnect() waits for the OS to report the link down before it
         * closes the client anyway. ble-plx completes a disconnect at once; this
         * bounds the wait (e.g. a peer out of range only drops at its
         * supervision timeout) while normally reporting the real link-down.
         */
        const val DISCONNECT_TIMEOUT_MS = 3_000L

        /** ble-plx's RefreshGattCustomOperation waits this long after BluetoothGatt.refresh(). */
        const val REFRESH_SETTLE_MS = 1_000L

        /** Client Characteristic Configuration descriptor. */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** A value the framework left null: no bytes. */
        val EMPTY_VALUE = ByteArray(0)
    }
}

/** Runs the operation timeouts on the manager's handler thread. */
private class HandlerTimer(private val handler: Handler) : OperationTimer {
    override fun schedule(task: Runnable, delayMs: Long) {
        handler.postDelayed(task, delayMs)
    }

    override fun cancel(task: Runnable) {
        handler.removeCallbacks(task)
    }
}
