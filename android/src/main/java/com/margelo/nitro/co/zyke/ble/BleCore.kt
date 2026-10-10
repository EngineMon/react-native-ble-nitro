package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import com.margelo.nitro.core.ArrayBuffer
import java.util.Collections
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask

/** The adapter, the system service it came from and the app context they belong to. */
internal class Bluetooth(val context: Context, val manager: BluetoothManager, val adapter: BluetoothAdapter)

/**
 * All state of one manager and the serial executor that owns it. The facade
 * ([BleNitroBleManager]) validates inputs, wraps the user callbacks through
 * the [CallbackGate] and calls these methods from any thread; each hops onto
 * the executor itself.
 *
 * Threading (NativeBleNitro.nitro.ts, section "Threading"):
 * - One HandlerThread per manager owns the links, the scan, the adapter
 *   state, the observers and the Bluetooth-enable requests. It receives every
 *   BluetoothGattCallback (see [GattConnection]), the adapter broadcasts (the
 *   receiver is registered with its Handler) and, through [osEvents], the OS
 *   events of other threads. Calls run in call order (FIFO Handler queue).
 * - Methods with a callback always post their work ([perform]), also when
 *   they fail at once: no callback runs inline on the caller's thread, and
 *   one that calls back into the manager is never re-entered.
 * - Synchronous methods ([query]) block until the executor ran them, or run
 *   inline on it, and never invoke a user callback (its caller is blocked).
 * - Observer registrations ([register]) run inline on the executor, else
 *   posted; an unregistration that runs first cancels the queued one.
 * - Every state transition completes before a callback about it fires (a C++
 *   callback may call a getter inline and must see the state it is told
 *   about). An event that ends several links (Bluetooth off, destroy) closes
 *   them all through [GattConnection.closeAll] before any callback fires.
 *
 * Destroy (NativeBleNitro.nitro.ts, section "After destroy()"): [destroy]
 * closes the [gate] (listeners fall silent, completions fail with
 * BluetoothManagerDestroyed), waits for a barrier so no listener still runs,
 * and posts the teardown. A task that runs after the gate closed fails its
 * caller instead ([perform]). The teardown ends everything and quits the
 * thread with quitSafely(): tasks posted before still run, later posts are
 * refused, and a refused call completes on [afterDestroy], one process-wide
 * thread, still asynchronously and exactly once. The routing follows
 * Handler.post()'s return value, so no call is lost between a check and a
 * post.
 */
internal class BleCore(private val gate: CallbackGate) : LinkOwner {
    private val thread = HandlerThread("BleNitro").apply { start() }
    private val handler = Handler(thread.looper)

    /**
     * Runs an OS event (scan callbacks, activity results) on the executor,
     * and drops it once destroy() was called: the teardown ends whatever the
     * event was about, and every listener is silent anyway.
     */
    private val osEvents = Executor { event -> handler.post { if (gate.isOpen) event.run() } }

    /**
     * Ids of observer registrations posted from another thread that haven't
     * run yet. A synchronous unregistration that runs first (inline on the
     * executor, e.g. from a C++ callback that got the id through shared state)
     * finds no observer; it removes the id here, and the registration then
     * skips its add. Without it the late add would install an observer whose
     * unregistration already returned, which nothing could ever remove.
     */
    private val queuedRegistrations: MutableSet<Long> = Collections.newSetFromMap(ConcurrentHashMap())

    // Everything below is touched on the executor only.
    private var bluetooth: Bluetooth? = null
    private val links = HashMap<String, GattConnection>()
    private val scanner = BleScanner(osEvents) { address -> links[address]?.isConnected == true }
    private val enableRequest = BluetoothEnableRequest(osEvents)
    private val stateObservers = ObserverSet<BLEState>()

    /** Every link emits its Connected, Disconnected and ServicesChanged events here ([connectionEvent]). */
    private val connectionEvents = ObserverSet<ConnectionEvent>()

    private val adapterStateReceiver = object : BroadcastReceiver() {
        // Registered with the handler, so this runs on the executor.
        override fun onReceive(context: Context, intent: Intent) {
            onAdapterStateChanged(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR))
        }
    }

    init {
        live.add(this)
        // Registers the adapter state receiver right away: links must be dropped
        // when Bluetooth turns off even if nobody subscribed to state changes.
        osEvents.execute { bluetooth() }
    }

    // Scanning (see [BleScanner])

    fun startScan(serviceUuids: List<UUID>, filter: ScanFilter, callbacks: ScanCallbacks) = perform(callbacks.startFailure) {
        val bluetooth = bluetooth() ?: return@perform callbacks.startFailure.fail(unsupportedError())
        scanner.start(bluetooth, serviceUuids, filter, callbacks)
    }

    /** Returns whether a scan was running. Its callbacks get nothing more. */
    fun stopScan(): Boolean = query(false) { scanner.stop() }

    fun isScanning(): Boolean = query(false) { scanner.isScanning }

    /**
     * NativeBleNitro.nitro.ts, getConnectedDevices: this manager's links that
     * are up and match [filter], then, for [ServiceFilter.Any] only, the other
     * devices the OS has a GATT connection to (another app's, or one this
     * manager no longer holds) with isConnected = false. Android lists those
     * without their services, so a filter can't be applied to them: with one
     * they are left out rather than reported unfiltered.
     */
    fun getConnectedDevices(filter: ServiceFilter): Array<BLEDevice> = query(emptyArray()) {
        val devices = ArrayList<BLEDevice>()
        for (link in links.values) {
            val matches = when (filter) {
                ServiceFilter.Any -> true
                is ServiceFilter.AnyOf -> link.offersAnyService(filter.uuids)
            }
            if (link.isConnected && matches) devices.add(connectedDevice(link.device, isConnected = true))
        }
        if (filter == ServiceFilter.Any) {
            bluetooth()?.let { bluetooth ->
                for (device in osGattConnectedDevices(bluetooth.manager)) {
                    if (links[device.address]?.isConnected != true) devices.add(connectedDevice(device, isConnected = false))
                }
            }
        }
        devices.toTypedArray()
    }

    // Connection management

    /**
     * NativeBleNitro.nitro.ts, connect. A link to the device that is up or
     * still connecting answers the call itself ([GattConnection.connectAgain]:
     * the up link succeeds and takes a present disconnect callback, a pending
     * connect makes this one fail with DeviceAlreadyConnected). A link still
     * going down after disconnect() is closed by it at once, and a fresh one
     * opens, so a stale BluetoothGatt never lingers next to the new one.
     */
    fun connect(
        deviceId: String,
        autoConnect: Boolean,
        refreshGatt: Boolean,
        deadline: GattRules.ConnectDeadline,
        reply: Reply<Unit, BleError>,
        onDisconnect: Once<ConnectionEvent>?,
    ) = perform(reply) {
        links[deviceId]?.let { if (it.connectAgain(onDisconnect, reply)) return@perform }
        val bluetooth = bluetooth() ?: return@perform reply.fail(unsupportedError())
        if (!bluetooth.adapter.isEnabled) return@perform reply.fail(poweredOffError("connect to $deviceId"))
        val link = GattConnection(deviceId, bluetooth.adapter.getRemoteDevice(deviceId), handler, refreshGatt, reply, onDisconnect, this)
        // Registered before open(): a connect that fails inside open() closes
        // the link at once, and linkClosed must find it to unregister it.
        links[deviceId] = link
        link.open(bluetooth.context, autoConnect, deadline)
    }

    /** DeviceNotConnected when there is neither a link nor a pending connect. */
    fun disconnect(deviceId: String, reply: Reply<Unit, BleError>) = onLink(deviceId, reply) { it.disconnect(reply) }

    fun isConnected(deviceId: String): Boolean = query(false) { links[deviceId]?.isConnected == true }

    fun mtu(deviceId: String): Double? = query<Double?>(null) { links[deviceId]?.mtu?.toDouble() }

    fun requestMtu(deviceId: String, mtu: Double, reply: Reply<Double, BleError>) = onLink(deviceId, reply) { it.requestMtu(mtu, reply) }

    fun requestConnectionPriority(deviceId: String, priority: AndroidConnectionPriority, reply: Reply<Unit, BleError>) =
        onLink(deviceId, reply) { link ->
            val osPriority = when (priority) {
                AndroidConnectionPriority.HIGH -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
                AndroidConnectionPriority.LOWPOWER -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
                AndroidConnectionPriority.BALANCED -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
            }
            link.requestConnectionPriority(osPriority, reply)
        }

    fun readRssi(deviceId: String, reply: Reply<Double, BleError>) = onLink(deviceId, reply) { it.readRssi(reply) }

    // Services and characteristics

    fun discoverServices(deviceId: String, reply: Reply<Unit, BleError>) = onLink(deviceId, reply) { it.discoverServices(reply) }

    fun services(deviceId: String): Array<String> = query(emptyArray()) { links[deviceId]?.services() ?: emptyArray() }

    fun characteristics(deviceId: String, service: UUID): Array<String> =
        query(emptyArray()) { links[deviceId]?.characteristics(service) ?: emptyArray() }

    fun characteristicProperties(deviceId: String, key: CharacteristicKey): CharacteristicProperties? =
        query<CharacteristicProperties?>(null) { links[deviceId]?.characteristicProperties(key) }

    fun read(deviceId: String, key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) =
        onLink(deviceId, reply) { it.read(key, reply) }

    /** [value] is the facade's own copy of the caller's bytes. */
    fun write(deviceId: String, key: CharacteristicKey, value: ByteArray, withResponse: Boolean, reply: Reply<ArrayBuffer, BleError>) =
        onLink(deviceId, reply) { it.write(key, value, withResponse, reply) }

    /** Adds subscriber [id] (allocated by the facade, which returned it before this runs). */
    fun subscribe(
        id: Long,
        deviceId: String,
        key: CharacteristicKey,
        onValue: Listener<ArrayBuffer>,
        completion: Reply<Unit, BleError>,
        onEnded: Once<BleError>?,
    ) = onLink(deviceId, completion) { it.subscribe(id, key, onValue, completion, onEnded) }

    /**
     * Ends subscription [id]: asks each live link's hub, the only place an id
     * lives, so no separate index can go stale when a link goes down. An id of
     * a link that closed or was replaced, or one that ended, completes without
     * error: the subscription is over either way, and ids are never reused,
     * so it can't hit a newer subscription. [GattConnection.unsubscribe]
     * completes [reply] when the id is its own and touches nothing otherwise;
     * it adds or removes no link, so iterating the live map is safe.
     */
    fun unsubscribe(id: Long, reply: Reply<Unit, BleError>) = perform(reply) {
        for (link in links.values) {
            if (link.unsubscribe(id, reply)) return@perform
        }
        reply.succeed()
    }

    /**
     * NativeBleNitro.nitro.ts, isSubscribedToCharacteristic: an active
     * (completed, not ended) subscription of this manager exists on the
     * characteristic. Asked of the link whether it is up or going down, as on
     * iOS: after disconnect(), active subscriptions keep receiving until the
     * link is down, and its close ends them.
     */
    fun isSubscribed(deviceId: String, key: CharacteristicKey): Boolean =
        query(false) { links[deviceId]?.isSubscribed(key) == true }

    // Bluetooth state

    /** See [BluetoothEnableRequest]. */
    fun requestBluetoothEnable(reply: Reply<Unit, BleError>) = perform(reply) {
        val bluetooth = bluetooth() ?: return@perform reply.fail(unsupportedError())
        enableRequest.request(bluetooth.adapter, reply)
    }

    /**
     * The adapter's state only. Missing runtime permissions surface as
     * BluetoothUnauthorized errors of the operations that need them: granting
     * one later changes no adapter state, so a state that depended on it
     * would go stale.
     */
    fun state(): BLEState = query(BLEState.UNKNOWN) {
        val bluetooth = bluetooth() ?: return@query BLEState.UNSUPPORTED
        try {
            adapterStateToBleState(bluetooth.adapter.state)
        } catch (e: SecurityException) {
            // Up to API 30 getState() needs the install-time BLUETOOTH permission in the manifest.
            BLEState.UNAUTHORIZED
        }
    }

    fun addStateObserver(id: Long, listener: Listener<BLEState>) = register(id) { stateObservers.add(id, listener) }

    /** Synchronous: once it returns, the observer is never called again. */
    fun removeStateObserver(id: Long) = unregister(id) { stateObservers.remove(id) }

    fun addConnectionObserver(id: Long, listener: Listener<ConnectionEvent>) = register(id) { connectionEvents.add(id, listener) }

    /** Synchronous: once it returns, the observer is never called again. */
    fun removeConnectionObserver(id: Long) = unregister(id) { connectionEvents.remove(id) }

    /** Fails [failing] with [error] on the executor: how the facade fails a call whose input it rejected. */
    fun reject(failing: Failable<BleError>, error: BleError) = perform(failing) { failing.fail(error) }

    /** Completes [reply] without error on the executor: how the facade ends an unsubscribe whose id names nothing. */
    fun complete(reply: Reply<Unit, BleError>) = perform(reply) { reply.succeed() }

    /**
     * Stops the scan, closes every link, fails everything pending with
     * BluetoothManagerDestroyed, unregisters the adapter receiver and ends the
     * thread. Idempotent, callable from any thread, also from a callback.
     *
     * The first call closes the [gate] and posts the teardown; no call runs
     * callbacks on the caller's thread. EVERY call made off the executor (not
     * only the one that closed the gate) posts its own barrier task and waits
     * for it: a listener that passed the gate before it closed may still be
     * running on the executor, and each caller may free its listener state
     * once its own destroy() returned (destroyAll on reload racing the
     * owner's destroy(), or an owner calling destroy() after a listener did).
     * The closing call's barrier runs ahead of the teardown, so it doesn't
     * wait for it; a later call's may run after it. A refused post means the
     * teardown already quit the thread: nothing runs there, nothing to wait
     * for. The barrier runs no callback itself.
     * On the executor (from a callback) nothing else can be running, so it doesn't
     * wait. Threading rule 4 applies: the caller must not hold a lock its BLE
     * callbacks take. JS callbacks never hold the executor (Nitro queues
     * them for the JS thread).
     */
    fun destroy() {
        val closedHere = gate.close()
        val barrier = if (Looper.myLooper() === handler.looper) null else FutureTask<Unit>({}, Unit)
        // Refused: the teardown already quit the thread, nothing runs there anymore.
        val mustWait = barrier != null && handler.post(barrier)
        if (closedHere) {
            live.remove(this)
            // Never refused: only the teardown quits the thread, and it is
            // posted once, here, behind this call's barrier (FIFO queue).
            handler.post { teardown() }
        }
        if (mustWait) awaitUninterruptibly(barrier!!)
    }

    /** Waits for [task]; an interrupt doesn't cut the wait short (destroy()'s guarantee), it is restored afterwards. */
    private fun awaitUninterruptibly(task: FutureTask<Unit>) {
        var interrupted = false
        while (true) {
            try {
                task.get()
                break
            } catch (e: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }

    // LinkOwner: called by the links, on the executor

    /** The state phase of a link's close: unregister it unless a newer link to the device replaced it. */
    override fun linkClosed(link: GattConnection) {
        if (links[link.deviceId] === link) links.remove(link.deviceId)
    }

    override fun connectionEvent(event: ConnectionEvent) = connectionEvents.emit(event)

    /** destroy() was called: the gate is closed. Sessions refuse to start queued operations from then on (no GATT request reaches the device after destroy()). */
    override val isDestroying: Boolean
        get() = !gate.isOpen

    // Teardown

    private fun teardown() {
        scanner.stop()
        bluetooth?.context?.unregisterReceiver(adapterStateReceiver)
        // Every completion fails with BluetoothManagerDestroyed; every listener
        // (disconnect callbacks, subscription ends, Disconnected) is silent: the
        // gate is closed.
        GattConnection.closeAll(links.values.toList(), LinkEnd.Destroyed)
        enableRequest.finish(destroyedError())
        stateObservers.clear()
        connectionEvents.clear()
        queuedRegistrations.clear()
        // Lets the tasks posted before this point run (they find the gate
        // closed and fail with BluetoothManagerDestroyed); delayed timeouts are
        // dropped, and every later post is refused (see [perform]).
        thread.quitSafely()
    }

    // Executor plumbing

    /**
     * Runs [task] on the executor, later: the one entry of every call with a
     * callback. Once destroy() was called, [failing] gets
     * BluetoothManagerDestroyed instead: on the executor while it runs, on
     * [afterDestroy] once its thread quit (decided by Handler.post()'s result,
     * so no call is lost between a check and a post).
     */
    private inline fun perform(failing: Failable<BleError>, crossinline task: () -> Unit) {
        val posted = handler.post { if (gate.isOpen) task() else failing.fail(destroyedError()) }
        if (!posted) afterDestroy.execute { failing.fail(destroyedError()) }
    }

    /** [perform] on the link to [deviceId]; DeviceNotConnected when there is none. */
    private inline fun onLink(deviceId: String, failing: Failable<BleError>, crossinline operation: (link: GattConnection) -> Unit) =
        perform(failing) {
            val link = links[deviceId]
            if (link == null) failing.fail(notConnectedError(deviceId)) else operation(link)
        }

    /**
     * Runs [block] on the executor and returns its result, blocking the caller
     * meanwhile (inline when called on the executor). Exceptions of [block]
     * are rethrown to the caller. [ifDestroyed] is the result once destroy()
     * was called. Compares against the Handler's looper, not the thread's:
     * HandlerThread.getLooper() returns null once the thread ended.
     */
    private fun <T> query(ifDestroyed: T, block: () -> T): T {
        if (!gate.isOpen) return ifDestroyed
        if (Looper.myLooper() === handler.looper) return block()
        val task = FutureTask(Callable { if (gate.isOpen) block() else ifDestroyed })
        // A refused post: destroyed. One accepted before quitSafely() still runs.
        if (!handler.post(task)) return ifDestroyed
        try {
            return task.get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }
    }

    /**
     * Adds observer [id]: inline on the executor, else posted and listed in
     * [queuedRegistrations] until it runs, so an unregistration can cancel
     * it. Dropped once destroy() was called: it would never fire.
     */
    private inline fun register(id: Long, crossinline add: () -> Unit) {
        if (!gate.isOpen) return
        if (Looper.myLooper() === handler.looper) return add()
        queuedRegistrations.add(id)
        val posted = handler.post { if (queuedRegistrations.remove(id) && gate.isOpen) add() }
        // Refused: destroyed meanwhile; the observer would never fire anyway.
        if (!posted) queuedRegistrations.remove(id)
    }

    /** Removes observer [id] synchronously, or cancels its registration when that is still queued. */
    private fun unregister(id: Long, remove: () -> Boolean) {
        query(Unit) { if (!remove()) queuedRegistrations.remove(id) }
    }

    /**
     * The adapter, resolved on first use (registering the adapter state
     * receiver then). Null without Bluetooth LE (state() reports Unsupported,
     * and every call needing the adapter fails with BluetoothUnsupported: one
     * rule for both), or when no app context could be found.
     */
    private fun bluetooth(): Bluetooth? {
        bluetooth?.let { return it }
        val context = BleNitroLifecycle.appContext() ?: return null
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) return null
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return null
        val adapter = manager.adapter ?: return null
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Not exported: the system's broadcasts still arrive, other apps' don't.
            context.registerReceiver(adapterStateReceiver, filter, null, handler, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(adapterStateReceiver, filter, null, handler)
        }
        return Bluetooth(context, manager, adapter).also { bluetooth = it }
    }

    /**
     * Bluetooth turning off ends the scan with BluetoothPoweredOff and drops
     * every link (pending operations fail, the gatts are closed, connected
     * links get their disconnect callback with interrupted = true); turning on
     * completes the waiting requestBluetoothEnable calls. Every state change
     * comes first, the callbacks after it, the state observers last.
     */
    private fun onAdapterStateChanged(adapterState: Int) {
        // A broadcast queued before destroy(): the teardown ends everything.
        if (!gate.isOpen) return
        when (adapterState) {
            BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                val scanEnded = scanner.abandon()
                GattConnection.closeAll(links.values.toList(), LinkEnd.BluetoothUnavailable)
                scanEnded?.fire(scanStoppedByBluetoothOffError())
            }
            BluetoothAdapter.STATE_ON -> enableRequest.adapterOn()
        }
        stateObservers.emit(adapterStateToBleState(adapterState))
    }

    companion object {
        /**
         * Every core not destroyed yet, for [destroyAll]. Strong references are
         * no new leak: a live core is already held by its adapter receiver and
         * its thread, whether or not its facade is still reachable.
         */
        private val live: MutableSet<BleCore> = Collections.newSetFromMap(ConcurrentHashMap())

        /**
         * Completes the calls that arrive after a manager's thread quit: one
         * daemon thread for the whole process (a destroyed manager has no
         * thread left), so they still complete asynchronously, never inline on
         * the caller, in the order they came.
         */
        private val afterDestroy: Executor by lazy {
            Executors.newSingleThreadExecutor { task -> Thread(task, "BleNitro-destroyed").apply { isDaemon = true } }
        }

        /**
         * Destroys every live manager, when React Native invalidates its
         * instance (a JS reload or the host's teardown, see
         * [BleNitroLifecycle]). Assumes one React instance per process: every
         * live manager belongs to the runtime going away (a host running two
         * React instances would lose the other one's managers too). Each
         * destroy() waits only for its manager's barrier, not its teardown.
         */
        fun destroyAll() {
            for (core in live.toList()) core.destroy()
        }
    }
}
