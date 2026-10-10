package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.util.Log
import com.margelo.nitro.core.ArrayBuffer
import java.util.UUID

private const val TAG = "BleNitro"

/** What a link tells, and asks, the manager that owns it ([BleCore]), on the executor. */
internal interface LinkOwner {
    /**
     * destroy() was called (from any thread): no GATT request may reach the
     * device from then on, though the teardown that closes the links runs
     * later ([GattSession] refuses to start operations).
     */
    val isDestroying: Boolean

    /**
     * The link closed: unregister it. Called in the state phase of its close
     * ([GattConnection]'s close funnel), before any callback of the close
     * fires, so a callback that asks about the device sees it gone.
     */
    fun linkClosed(link: GattConnection)

    /** The link's Connected, Disconnected or ServicesChanged event, for the manager's connection observers. */
    fun connectionEvent(event: ConnectionEvent)
}

/**
 * Why a link ends: one value per close, from which [GattConnection] derives,
 * in one place, everything its close tells (see [GattConnection.closeAll]).
 * The manager ends links with [BluetoothUnavailable] and [Destroyed]; the
 * other ends come from the link itself. iOS has the same type
 * (ios/PeripheralLink.swift).
 */
internal sealed interface LinkEnd {
    /**
     * The connect attempt ended before the link was the caller's: connectGatt
     * failed, the caller's timeout passed, or disconnect() cancelled it. The
     * pending connect fails with [error].
     */
    class ConnectFailed(val error: BleError) : LinkEnd

    /**
     * The OS reported the link down with GATT/HCI [status] (or a connection
     * state change failed with it). [osMayHoldLink]: the OS reported a
     * failure while still connected, so the client is disconnected before it
     * is closed.
     */
    class Lost(val status: Int, val osMayHoldLink: Boolean) : LinkEnd

    /**
     * disconnect() was called, and the client is closed without waiting
     * longer for the OS to report the link down (that report is late, or a
     * new connect to the device needs the link gone now).
     */
    data object DisconnectForced : LinkEnd

    /** [operation] got no answer within [timeoutMs] and stalled the link (see [GattOperationQueue]). */
    class Stalled(val operation: String, val timeoutMs: Long) : LinkEnd

    /** Bluetooth is turning off. */
    data object BluetoothUnavailable : LinkEnd

    /** The manager is destroyed. */
    data object Destroyed : LinkEnd
}

/**
 * One GATT link to one device: the connect/disconnect state machine, the
 * BluetoothGatt, and the close funnel every way the link ends goes through.
 * The link's GATT work (operations, subscriptions, MTU, discovered database)
 * lives in its [GattSession], created when the link comes up; its OS
 * callbacks arrive through its [LinkCallback]. Created and owned by
 * [BleCore], one object per link: a reconnect creates a new one, so nothing
 * of a previous link survives into the next. iOS has the same layer
 * (ios/PeripheralLink.swift).
 *
 * Every method runs on the manager's executor (the handler thread). Internal
 * code holds user callbacks only as [Reply], [Once] and [Listener] (wrapped
 * once by the facade), which run them at most once (Reply/Once) and never
 * let a throw escape into this class. Every state change completes before
 * any callback of it fires: a C++ callback runs inline on this thread and may
 * call the synchronous getters (isConnected, mtu, isSubscribed, ...), which
 * must already see the new state.
 *
 * Connection lifecycle (NativeBleNitro.nitro.ts, connect, disconnect and
 * ConnectionEventType):
 * - Connect fails with DeviceConnectionFailed + the GATT status when the link
 *   goes down before it was ever up (e.g. 133), with DeviceDisconnected + the
 *   status when it drops while the GATT cache refresh settles, with
 *   OperationTimedOut after the caller's timeout, and with OperationCancelled
 *   when disconnect() cancels it. Every failure closes the BluetoothGatt. The
 *   connect timeout cancels the OS attempt (disconnect + close), and the
 *   closed link ignores its late report.
 * - ConnectOptions.refreshGatt: the GATT cache is refreshed once the link is
 *   up, and connect completes after it ([refreshCache]).
 * - A connect that succeeds emits the Connected connection event, in the same
 *   task and right before its success callback.
 * - connect() on the device again: see [connectAgain].
 * - The disconnect callback fires once, only for a link whose connect
 *   succeeded (that emitted Connected): interrupted = false with no error
 *   after disconnect() or destroy(); otherwise interrupted = true with
 *   DeviceDisconnected + the GATT status when the link was lost, or
 *   OperationTimedOut when an operation timeout took the link down. The
 *   Disconnected connection event follows it with the same values.
 * - disconnect() fails the queued operations at once with DeviceDisconnected
 *   (no new procedure on a link that is going down), and completes once the
 *   OS reports the link down, or after [DISCONNECT_TIMEOUT_MS] without that
 *   report (the client is closed then).
 * - Every way the link ends goes through one close funnel, [beginClose]: a
 *   state phase, then the firing; its order is documented there.
 */
internal class GattConnection(
    val deviceId: String,
    val device: BluetoothDevice,
    private val handler: Handler,
    private val refreshGatt: Boolean,
    connectReply: Reply<Unit, BleError>,
    onDisconnect: Once<ConnectionEvent>?,
    private val owner: LinkOwner,
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

    private var state = State.CONNECTING
    private var gatt: BluetoothGatt? = null

    /** The link's GATT work, from the moment it is up; closed by the close funnel. */
    private var session: GattSession? = null
    private var pendingConnect: Reply<Unit, BleError>? = connectReply

    /**
     * This link's disconnect callback, fired once with the Disconnected
     * [ConnectionEvent]. [connectAgain] replaces it when it brings a new one.
     */
    private var disconnectCallback: Once<ConnectionEvent>? = onDisconnect

    /** The connect succeeded and Connected was emitted: the link gets a disconnect callback and a Disconnected event when it ends. */
    private var connectSucceeded = false
    private var connectTimeoutMs = 0L
    private val pendingDisconnects = ArrayList<Reply<Unit, BleError>>()

    private val connectTimeout = Runnable { close(LinkEnd.ConnectFailed(connectTimedOutError(deviceId, connectTimeoutMs))) }

    private val refreshSettled = Runnable { finishConnect() }

    private val disconnectTimeout = Runnable {
        Log.w(TAG, "$deviceId reported no disconnection within $DISCONNECT_TIMEOUT_MS ms of disconnect(); closing its GATT client")
        close(LinkEnd.DisconnectForced)
    }

    /** What [LinkCallback] reports to; private so its entry points aren't part of this class's API. */
    private val events = object : LinkEvents {
        override val isOpen: Boolean
            get() = state != State.CLOSED

        override val session: GattSession?
            get() = this@GattConnection.session

        override fun connectionStateChanged(status: Int, newState: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                onLinkUp()
            } else if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                close(LinkEnd.Lost(status, osMayHoldLink = newState == BluetoothProfile.STATE_CONNECTED))
            }
        }

        override fun servicesChanged() = onServicesChanged()
    }

    /** The link is up and its connect succeeded. Operations need this (DeviceNotConnected otherwise). */
    val isConnected: Boolean
        get() = state == State.CONNECTED && pendingConnect == null

    /**
     * The session of the link while it [isConnected]: every operation and
     * getter goes through it, so none can skip the check.
     */
    private val upSession: GattSession?
        get() = if (isConnected) session else null

    /** The ATT MTU in effect ([GattSession.mtu]); null when the link isn't connected. */
    val mtu: Int?
        get() = upSession?.mtu

    /** Starts connecting; [deadline] [GattRules.ConnectDeadline.Never] leaves the timeout to the OS (about 30 s with autoConnect false, none with autoConnect true). */
    fun open(context: Context, autoConnect: Boolean, deadline: GattRules.ConnectDeadline) {
        val callback = LinkCallback(handler, events)
        val opened = try {
            if (LinkCallback.CALLED_ON_HANDLER) {
                device.connectGatt(context, autoConnect, callback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, handler)
            } else {
                device.connectGatt(context, autoConnect, callback, BluetoothDevice.TRANSPORT_LE)
            }
        } catch (e: SecurityException) {
            close(LinkEnd.ConnectFailed(unauthorizedError("Connecting to $deviceId", e)))
            return
        }
        if (opened == null) {
            close(LinkEnd.ConnectFailed(gattClientUnavailableError(deviceId)))
            return
        }
        gatt = opened
        if (deadline is GattRules.ConnectDeadline.After) {
            connectTimeoutMs = deadline.ms
            handler.postDelayed(connectTimeout, deadline.ms)
        }
    }

    /**
     * connect() on a device this link belongs to (NativeBleNitro.nitro.ts,
     * connect). Returns true when this link answered [reply]:
     * - a connect is still pending (also while the GATT cache refresh
     *   settles): [reply] fails with DeviceAlreadyConnected, the pending one
     *   goes on;
     * - the link is up: [reply] succeeds at once; a present [onDisconnect]
     *   replaces the installed disconnect callback, an absent one keeps it.
     * Returns false, without touching [reply], when the caller must open a
     * new link: this one is going down after disconnect(), and is closed now
     * (its pending disconnect() calls complete), so a stale BluetoothGatt
     * never lingers next to the new one; or it is already closed.
     */
    fun connectAgain(onDisconnect: Once<ConnectionEvent>?, reply: Reply<Unit, BleError>): Boolean =
        when (state) {
            State.CONNECTING -> {
                reply.fail(alreadyConnectingError(deviceId))
                true
            }
            State.CONNECTED -> {
                if (pendingConnect != null) {
                    reply.fail(alreadyConnectingError(deviceId))
                } else {
                    if (onDisconnect != null) disconnectCallback = onDisconnect
                    reply.succeed()
                }
                true
            }
            State.DISCONNECTING -> {
                close(LinkEnd.DisconnectForced)
                false
            }
            State.CLOSED -> false
        }

    /**
     * Takes the link down. A connect that is still pending fails with
     * OperationCancelled, the queued operations fail at once with
     * DeviceDisconnected; [reply] completes once the link is down. The
     * subscriptions end when the link closes, with DeviceDisconnected (Active
     * ones keep receiving until then; a Pending one's completion fails then).
     */
    fun disconnect(reply: Reply<Unit, BleError>) {
        when (state) {
            State.CONNECTING -> {
                // The link never came up: there is nothing to tear down but the
                // pending connect, which Android may never report as ended.
                pendingDisconnects.add(reply)
                close(LinkEnd.ConnectFailed(connectCancelledError(deviceId)))
            }
            State.CONNECTED -> {
                try {
                    checkNotNull(gatt).disconnect()
                } catch (e: SecurityException) {
                    reply.fail(unauthorizedError("Disconnecting from $deviceId", e))
                    return
                }
                state = State.DISCONNECTING
                pendingDisconnects.add(reply)
                handler.postDelayed(disconnectTimeout, DISCONNECT_TIMEOUT_MS)
                // The link came up but connect still waited for the GATT cache
                // refresh: no operation can be queued yet (the link isn't
                // connected for callers), so failing the connect last still
                // fires after every state change.
                val connect = pendingConnect
                pendingConnect = null
                handler.removeCallbacks(connectTimeout)
                handler.removeCallbacks(refreshSettled)
                checkNotNull(session).closeOperations(disconnectingError(deviceId))
                connect?.fail(connectCancelledError(deviceId))
            }
            State.DISCONNECTING -> pendingDisconnects.add(reply)
            State.CLOSED -> reply.fail(notConnectedError(deviceId))
        }
    }

    /**
     * [mtu] must be an integer in 23...517 ([GattRules.validMtuRequest]);
     * anything else fails with DeviceMTUChangeFailed before reaching the OS (a
     * fraction would be truncated, NaN would become 0). Checked in the
     * contract's order, as on iOS: a link that isn't connected fails with
     * DeviceNotConnected first, whatever [mtu] is.
     */
    fun requestMtu(mtu: Double, reply: Reply<Double, BleError>) = onSession(reply) { session ->
        val requested = GattRules.validMtuRequest(mtu) ?: return@onSession reply.fail(invalidMtuError(mtu))
        session.requestMtu(requested, reply)
    }

    /** [priority] is a BluetoothGatt.CONNECTION_PRIORITY_* value. */
    fun requestConnectionPriority(priority: Int, reply: Reply<Unit, BleError>) =
        onSession(reply) { it.requestConnectionPriority(priority, reply) }

    fun readRssi(reply: Reply<Double, BleError>) = onSession(reply) { it.readRssi(reply) }

    fun discoverServices(reply: Reply<Unit, BleError>) = onSession(reply) { it.discoverServices(reply) }

    fun read(key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) = onSession(reply) { it.read(key, reply) }

    /** [value] is the caller's own copy (the facade copies it on the calling thread). */
    fun write(key: CharacteristicKey, value: ByteArray, withResponse: Boolean, reply: Reply<ArrayBuffer, BleError>) =
        onSession(reply) { it.write(key, value, withResponse, reply) }

    /** See [GattSession.subscribe]. */
    fun subscribe(id: Long, key: CharacteristicKey, onValue: Listener<ArrayBuffer>, completion: Reply<Unit, BleError>, onEnded: Once<BleError>?) =
        onSession(completion) { it.subscribe(id, key, onValue, completion, onEnded) }

    /**
     * Ends subscription [id] when it is this link's ([GattSession.unsubscribe]).
     * Also while the link is going down after disconnect(): the subscription
     * still exists then, and its unsubscribe completes without error. Returns
     * false, without touching [reply], when [id] isn't a live subscription of
     * this link.
     */
    fun unsubscribe(id: Long, reply: Reply<Unit, BleError>): Boolean = session?.unsubscribe(id, reply) == true

    /**
     * Whether [key] has an Active subscriber. Also true while the link is
     * going down after disconnect(), as Active subscriptions keep receiving
     * until it is down; the close funnel ends them, and an unregistered link
     * isn't asked anymore.
     */
    fun isSubscribed(key: CharacteristicKey): Boolean = session?.isSubscribed(key) == true

    /** UUIDs of the discovered services; empty when not connected or nothing valid is discovered. */
    fun services(): Array<String> = upSession?.services() ?: emptyArray()

    /** UUIDs of the discovered characteristics of [service]; empty when unknown. */
    fun characteristics(service: UUID): Array<String> = upSession?.characteristics(service) ?: emptyArray()

    /** Whether the link is connected and its discovered services include one of [services]. */
    fun offersAnyService(services: Collection<UUID>): Boolean = upSession?.offersAnyService(services) == true

    /** The declared properties of [key]; null when not connected or the lookup fails. */
    fun characteristicProperties(key: CharacteristicKey): CharacteristicProperties? = upSession?.characteristicProperties(key)

    /** Runs [operation] on the session of the connected link; [failing] gets DeviceNotConnected otherwise. */
    private inline fun onSession(failing: Failable<BleError>, operation: (session: GattSession) -> Unit) {
        val session = upSession
        if (session == null) failing.fail(notConnectedError(deviceId)) else operation(session)
    }

    private fun onLinkUp() {
        if (state != State.CONNECTING) return
        val gatt = checkNotNull(gatt)
        state = State.CONNECTED
        session = GattSession(deviceId, gatt, handler, owner) { stalled ->
            close(LinkEnd.Stalled(stalled.description, stalled.timeoutMs))
        }
        if (refreshGatt) refreshCache(gatt) else finishConnect()
    }

    /**
     * ConnectOptions.refreshGatt: BluetoothGatt.refresh() drops the OS's GATT
     * cache of the device, so the next discovery reads the database from the
     * peripheral; connect completes [REFRESH_SETTLE_MS] later, which gives the
     * stack a moment to drop its cache before the caller's first procedure
     * (no operation can run before: the link isn't connected for callers
     * until then). refresh() is a hidden, non-SDK method (not part of the
     * public SDK; Android's restrictions on non-SDK interfaces may block it
     * in a future release), so it is called by reflection, and only when the
     * caller opted in. A failure is tolerated: when the method is missing or
     * blocked, throws or returns false, it is logged and the connect goes on
     * (the cache may be stale then).
     */
    private fun refreshCache(gatt: BluetoothGatt) {
        val refreshed = try {
            gatt.javaClass.getMethod("refresh").invoke(gatt) as? Boolean
        } catch (e: ReflectiveOperationException) {
            Log.w(TAG, "BluetoothGatt.refresh() failed for $deviceId; its GATT cache may be stale", e)
            null
        } catch (e: RuntimeException) {
            Log.w(TAG, "BluetoothGatt.refresh() failed for $deviceId; its GATT cache may be stale", e)
            null
        }
        if (refreshed == false) Log.w(TAG, "BluetoothGatt.refresh() returned false for $deviceId; its GATT cache may be stale")
        handler.postDelayed(refreshSettled, REFRESH_SETTLE_MS)
    }

    /** The connect succeeded: Connected first, then the success callback, in this task. */
    private fun finishConnect() {
        val connect = pendingConnect ?: return
        handler.removeCallbacks(connectTimeout)
        pendingConnect = null
        connectSucceeded = true
        owner.connectionEvent(ConnectionEvent(deviceId, ConnectionEventType.CONNECTED, interrupted = false, error = null))
        connect.succeed()
    }

    /**
     * Service Changed (API 31+; see [GattSession.servicesChanged]), then the
     * ServicesChanged connection event, for a link that emitted Connected.
     * Only a link that is up has a database and subscriptions to end. A link
     * that is connecting has neither; one that is disconnecting keeps its
     * subscriptions until the close funnel ends them with DeviceDisconnected
     * (disconnect() by anyone ends them with that, and a ServicesChanged
     * event for a link going down would make a listener react to a link it is
     * already tearing down).
     */
    private fun onServicesChanged() {
        if (state != State.CONNECTED) return
        checkNotNull(session).servicesChanged()
        if (connectSucceeded) {
            owner.connectionEvent(ConnectionEvent(deviceId, ConnectionEventType.SERVICESCHANGED, interrupted = false, error = null))
        }
    }

    /** What the pending callbacks of a closing link get; derived from its [LinkEnd] by [closing] only. */
    private class Closing(
        /** A connect that is still pending. */
        val connectError: BleError,
        /** Every queued or running operation. */
        val operationError: BleError,
        /** Every subscription: a Pending one's completion, an Active one's onEnded. */
        val subscriptionError: BleError,
        /** Pending disconnect() calls; null completes them without error. */
        val disconnectError: BleError?,
        /** The disconnect callback's error: null when the link ended as asked (interrupted = false), else why it was interrupted. */
        val interruption: BleError?,
        /** The OS may still hold or still be opening the link: disconnect the client before closing it. */
        val disconnectFirst: Boolean,
    )

    /**
     * Every close-time choice, per [end], in one place (iOS: the same switch
     * in PeripheralLink). Reads [state] before the close changes it: a link
     * that is disconnecting ended as asked, so its disconnect callback isn't
     * interrupted (unless the manager is destroyed, which interrupts nothing).
     */
    private fun closing(end: LinkEnd): Closing {
        fun interruption(error: BleError) = if (state == State.DISCONNECTING) null else error
        return when (end) {
            is LinkEnd.ConnectFailed -> Closing(
                connectError = end.error,
                operationError = end.error,
                subscriptionError = end.error,
                disconnectError = null,
                interruption = null,
                disconnectFirst = true,
            )
            is LinkEnd.Lost -> {
                val lost = linkLostError(deviceId, end.status)
                Closing(
                    connectError = if (state == State.CONNECTING) connectionFailedError(deviceId, end.status) else lost,
                    operationError = lost,
                    subscriptionError = lost,
                    disconnectError = null,
                    interruption = interruption(lost),
                    disconnectFirst = end.osMayHoldLink,
                )
            }
            LinkEnd.DisconnectForced -> {
                val down = disconnectedError(deviceId)
                Closing(
                    connectError = down,
                    operationError = down,
                    subscriptionError = down,
                    disconnectError = null,
                    interruption = null,
                    // disconnect() already asked the OS to disconnect.
                    disconnectFirst = false,
                )
            }
            is LinkEnd.Stalled -> {
                val timedOut = stalledError(deviceId, end.operation, end.timeoutMs)
                Closing(
                    connectError = timedOut,
                    operationError = stalledLinkError(deviceId),
                    subscriptionError = timedOut,
                    disconnectError = null,
                    interruption = interruption(timedOut),
                    disconnectFirst = true,
                )
            }
            LinkEnd.BluetoothUnavailable -> {
                val lost = bluetoothOffLinkLostError(deviceId)
                Closing(
                    connectError = poweredOffError("connect to $deviceId"),
                    operationError = lost,
                    subscriptionError = lost,
                    disconnectError = null,
                    interruption = interruption(lost),
                    disconnectFirst = true,
                )
            }
            LinkEnd.Destroyed -> {
                val destroyed = destroyedError()
                Closing(
                    connectError = destroyed,
                    operationError = destroyed,
                    subscriptionError = destroyed,
                    disconnectError = destroyed,
                    interruption = null,
                    disconnectFirst = true,
                )
            }
        }
    }

    /** [beginClose] and its firing at once: the link ends in this task, nothing else ends with it. */
    private fun close(end: LinkEnd) = beginClose(end)()

    /**
     * The one way a link ends, in two phases, because every state change
     * completes before any callback fires (a callback may call the
     * synchronous getters, which must see the link gone, and, when one event
     * ends several links ([closeAll]), see all of them gone):
     * 1. Here, the state phase: state = CLOSED, the timers are cancelled, the
     *    BluetoothGatt is released, the link is unregistered
     *    ([LinkOwner.linkClosed]), and everything that is to be told is
     *    collected.
     * 2. The returned firing, in this order: the pending connect, the queued
     *    and running operations, then the Pending subscriptions' completions
     *    and the Active subscriptions' onEnded ([GattSession.close]; an
     *    operation whose timeout took the link down fails first, with its own
     *    timeout), pending disconnect() calls, the disconnect callback, the
     *    Disconnected connection event (the last two only for a link that
     *    emitted Connected).
     * Only [close] and [closeAll] call it, and both run the firing in the
     * same executor task. A link that is already closed returns a firing that
     * does nothing.
     */
    private fun beginClose(end: LinkEnd): () -> Unit {
        if (state == State.CLOSED) return {}
        val closing = closing(end)
        state = State.CLOSED
        handler.removeCallbacks(connectTimeout)
        handler.removeCallbacks(refreshSettled)
        handler.removeCallbacks(disconnectTimeout)
        gatt?.let { release(it, closing.disconnectFirst) }
        gatt = null
        owner.linkClosed(this)
        val connect = pendingConnect
        pendingConnect = null
        val session = session
        val disconnects = pendingDisconnects.toList()
        pendingDisconnects.clear()
        val onDisconnect = disconnectCallback
        disconnectCallback = null
        val emitsDisconnected = connectSucceeded

        return {
            connect?.fail(closing.connectError)
            session?.close(closing.operationError, closing.subscriptionError)
            for (disconnect in disconnects) {
                val error = closing.disconnectError
                if (error == null) disconnect.succeed() else disconnect.fail(error)
            }
            if (emitsDisconnected) {
                val interruption = closing.interruption
                val event = ConnectionEvent(deviceId, ConnectionEventType.DISCONNECTED, interrupted = interruption != null, error = interruption)
                onDisconnect?.fire(event)
                owner.connectionEvent(event)
            }
        }
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

    companion object {
        /**
         * How long disconnect() waits for the OS to report the link down
         * before it closes the client anyway: the report normally comes
         * within a connection interval or two, but a peer out of range only
         * drops at its supervision timeout, and disconnect() must still
         * complete in bounded time.
         */
        private const val DISCONNECT_TIMEOUT_MS = 3_000L

        /** How long connect waits after BluetoothGatt.refresh() before it completes (see [refreshCache]). */
        private const val REFRESH_SETTLE_MS = 1_000L

        /**
         * Ends every link of [links] with [end], when one event ends several
         * (Bluetooth turning off, destroy): the state phase of every link
         * first, then every firing, in this task, so no callback of any of
         * them fires before all of them are closed and unregistered (a
         * callback may call the synchronous getters about another device,
         * e.g. isConnected or getConnectedDevices, which must already see
         * that device gone). A firing that throws (a bug: user callbacks never
         * throw out of their wrappers) still lets the others fire; the first
         * throwable is rethrown after them, the others suppressed into it.
         */
        fun closeAll(links: Collection<GattConnection>, end: LinkEnd) {
            val firings = links.map { it.beginClose(end) }
            var thrown: Throwable? = null
            for (fire in firings) {
                try {
                    fire()
                } catch (t: Throwable) {
                    val first = thrown
                    if (first == null) thrown = t else first.addSuppressed(t)
                }
            }
            thrown?.let { throw it }
        }
    }
}
