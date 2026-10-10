package com.margelo.nitro.co.zyke.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import kotlin.math.min

/**
 * Android implementation of the BLE Nitro Module. The behavior contract is the
 * documentation of src/specs/NativeBleNitro.nitro.ts.
 *
 * Threading:
 * - One HandlerThread per manager owns all state (links, scan, adapter state)
 *   and invokes every callback, JS or native, in event order. A callback
 *   created in C++ by another native module therefore runs directly on that
 *   thread, without the JS thread.
 * - Public methods hop onto it. Methods with a callback post their work and
 *   never run inline, so a callback that calls back into the manager is never
 *   re-entered and calls keep their order. Synchronous getters block until the
 *   thread ran them, or run inline when called on the thread itself.
 * - GATT callbacks reach the thread as described in [GattConnection], scan
 *   results (which the OS delivers on the main thread) are posted to it, and
 *   the adapter state receiver is registered with its Handler.
 * - After destroy() the thread is gone: a method with a callback then
 *   completes at once on the calling thread with BluetoothManagerDestroyed,
 *   and a getter returns its empty value.
 *
 * Errors: every failure of a method with a callback reaches the callback as a
 * [BleError] (codes like ble-plx's, see BleErrors.kt), never as an exception.
 * Synchronous getters throw instead: an invalid UUID string, or the
 * SecurityException of getConnectedDevices without BLUETOOTH_CONNECT.
 */
class BleNitroBleManager : HybridNativeBleNitroSpec() {

    // iOS only (CoreBluetooth state restoration); unused on Android.
    override var restoreStateIdentifier: String? = null

    /** The adapter and the app context it came from. */
    private class Bluetooth(val context: Context, val adapter: BluetoothAdapter)

    private val thread = HandlerThread("BleNitro").apply { start() }
    private val handler = Handler(thread.looper)

    // Everything below is touched on the handler thread only.
    private var destroyed = false
    private var bluetooth: Bluetooth? = null
    private var stateCallback: ((state: BLEState) -> Unit)? = null
    private val links = HashMap<String, GattConnection>()
    private var scan: ActiveScan? = null
    private val scanThrottle = ScanStartThrottle()
    private var scanPermissionNeverForLocation: Boolean? = null

    private val adapterStateReceiver = object : BroadcastReceiver() {
        // Registered with the handler, so this runs on the handler thread.
        override fun onReceive(context: Context, intent: Intent) {
            onAdapterStateChanged(intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR))
        }
    }

    init {
        // Registers the adapter state receiver right away: links must be dropped
        // when Bluetooth turns off even if nobody subscribed to state changes.
        handler.post { bluetooth() }
    }

    companion object {
        private const val TAG = "BleNitro"

        /** HCI "RSSI not available": the RSSI of a device known without an advertisement (iOS reports the same). */
        private const val RSSI_UNAVAILABLE = 127.0

        @Volatile
        private var appContext: Context? = null

        fun setContext(context: Context) {
            appContext = context.applicationContext
        }

        fun getContext(): Context? = appContext
    }

    override fun setRestoreStateCallback(callback: (restoredPeripherals: Array<BLEDevice>) -> Unit) {
        // iOS only (CoreBluetooth state restoration); Android has no equivalent.
    }

    override fun iosLazyInit() {
        // iOS only.
    }

    // Scanning

    override fun startScan(filter: ScanFilter, callback: (device: BLEDevice?, error: BleError?) -> Unit) {
        async({ callback(null, it) }) { beginScan(filter, callback) }
    }

    /** Returns whether a scan was running. No callback of it runs after this returns. */
    override fun stopScan(): Boolean = sync(false) { stopActiveScan() }

    override fun isScanning(): Boolean = sync(false) { scan != null }

    // Device discovery

    /**
     * Devices with a GATT connection to this phone, from any app. Android
     * reports these connections without their services, so [services] can't
     * narrow the list.
     */
    override fun getConnectedDevices(services: Array<String>): Array<BLEDevice> = sync(emptyArray()) {
        val bluetooth = bluetooth() ?: return@sync emptyArray()
        val manager = bluetooth.context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        manager.getConnectedDevices(BluetoothProfile.GATT).map { device ->
            BLEDevice(
                id = device.address,
                name = deviceName(device) ?: "",
                rssi = RSSI_UNAVAILABLE,
                manufacturerData = ManufacturerData(companyIdentifiers = emptyArray()),
                serviceData = ServiceData(services = emptyArray()),
                serviceUUIDs = emptyArray(),
                isConnectable = true,
                isConnected = true,
            )
        }.toTypedArray()
    }

    // Connection management

    /**
     * Connect semantics:
     * - device connected through this manager: succeeds at once and installs
     *   [disconnectCallback] in place of the previous one (spec)
     * - a connect to the device is still pending: fails with
     *   DeviceAlreadyConnected and leaves the pending one alone (ble-plx's code
     *   for a second connect: RxAndroidBle's BleAlreadyConnectedException)
     * - a disconnect() of the device still waits for the link to go down: that
     *   link is closed now and a fresh one opened, so a stale BluetoothGatt never
     *   lingers next to the new one
     */
    override fun connect(
        deviceId: String,
        options: ConnectOptions,
        callback: (error: BleError?) -> Unit,
        disconnectCallback: ((deviceId: String, interrupted: Boolean, error: BleError?) -> Unit)?,
    ) {
        async(callback) {
            val existing = links[deviceId]
            when {
                existing == null -> Unit
                existing.isConnecting -> return@async callback(
                    bleError(BleErrorCode.DEVICEALREADYCONNECTED, "A connection to $deviceId is already pending")
                )
                existing.isConnected -> {
                    existing.disconnectCallback = disconnectCallback
                    return@async callback(null)
                }
                else -> existing.finishDisconnect()
            }
            val bluetooth = bluetooth() ?: return@async callback(unsupportedError())
            if (!bluetooth.adapter.isEnabled) return@async callback(poweredOffError("connect to $deviceId"))
            if (!BluetoothAdapter.checkBluetoothAddress(deviceId)) {
                return@async callback(invalidIdentifiersError(deviceId))
            }
            val link = GattConnection(
                deviceId = deviceId,
                device = bluetooth.adapter.getRemoteDevice(deviceId),
                handler = handler,
                refreshGatt = options.refreshGatt == true,
                connectCallback = callback,
                disconnectCallback = disconnectCallback,
                onClosed = { closed -> if (links[closed.deviceId] === closed) links.remove(closed.deviceId) },
            )
            links[deviceId] = link
            link.open(bluetooth.context, autoConnect = options.autoConnect == true, timeoutMs = options.timeoutMs?.toLong())
        }
    }

    /** Fails with DeviceNotConnected when there is neither a link nor a pending connect (ble-plx). */
    override fun disconnect(deviceId: String, callback: (error: BleError?) -> Unit) {
        async(callback) {
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId))
            link.disconnect(callback)
        }
    }

    override fun isConnected(deviceId: String): Boolean = sync(false) { links[deviceId]?.isConnected == true }

    override fun requestMTU(deviceId: String, mtu: Double, callback: (error: BleError?, mtu: Double?) -> Unit) {
        async({ callback(it, null) }) {
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId), null)
            link.requestMtu(mtu.toInt(), callback)
        }
    }

    override fun requestConnectionPriority(
        deviceId: String,
        androidConnectionPriority: AndroidConnectionPriority,
        callback: (error: BleError?) -> Unit,
    ) {
        async(callback) {
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId))
            val priority = when (androidConnectionPriority) {
                AndroidConnectionPriority.HIGH -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
                AndroidConnectionPriority.LOWPOWER -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
                AndroidConnectionPriority.BALANCED -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
            }
            link.requestConnectionPriority(priority, callback)
        }
    }

    override fun readRSSI(deviceId: String, callback: (error: BleError?, rssi: Double?) -> Unit) {
        async({ callback(it, null) }) {
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId), null)
            link.readRssi(callback)
        }
    }

    // Service discovery

    override fun discoverServices(deviceId: String, callback: (error: BleError?) -> Unit) {
        async(callback) {
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId))
            link.discoverServices(callback)
        }
    }

    /** Android's service discovery includes the characteristics. */
    override fun discoverServicesWithCharacteristics(deviceId: String, callback: (error: BleError?) -> Unit) =
        discoverServices(deviceId, callback)

    override fun getServices(deviceId: String): Array<String> = sync(emptyArray()) {
        links[deviceId]?.services() ?: emptyArray()
    }

    override fun getCharacteristics(deviceId: String, serviceId: String): Array<String> = sync(emptyArray()) {
        links[deviceId]?.characteristics(UUID.fromString(serviceId)) ?: emptyArray()
    }

    // Characteristic operations

    override fun readCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: (error: BleError?, data: ArrayBuffer?) -> Unit,
    ) {
        async({ callback(it, null) }) {
            val key = characteristicKey(serviceId, characteristicId)
                ?: return@async callback(invalidIdentifiersError(serviceId, characteristicId), null)
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId), null)
            link.read(key, callback)
        }
    }

    override fun writeCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        data: ArrayBuffer,
        withResponse: Boolean,
        callback: (error: BleError?, responseData: ArrayBuffer?) -> Unit,
    ) {
        // Copied here, on the calling thread: a buffer from JS is valid only
        // during this call, and the caller may reuse it once the call returns.
        val source = data.getBuffer(false).duplicate()
        // Buffer.rewind(): ByteBuffer's covariant override is newer than minSdk.
        (source as java.nio.Buffer).rewind()
        val value = ByteArray(source.remaining())
        source.get(value)
        async({ callback(it, null) }) {
            val key = characteristicKey(serviceId, characteristicId)
                ?: return@async callback(invalidIdentifiersError(serviceId, characteristicId), null)
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId), null)
            link.write(key, value, withResponse, callback)
        }
    }

    override fun subscribeToCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        updateCallback: (data: ArrayBuffer) -> Unit,
        completionCallback: (error: BleError?) -> Unit,
    ) {
        async(completionCallback) {
            val key = characteristicKey(serviceId, characteristicId)
                ?: return@async completionCallback(invalidIdentifiersError(serviceId, characteristicId))
            val link = links[deviceId] ?: return@async completionCallback(notConnectedError(deviceId))
            link.subscribe(key, updateCallback, completionCallback)
        }
    }

    override fun unsubscribeFromCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: (error: BleError?) -> Unit,
    ) {
        async(callback) {
            val key = characteristicKey(serviceId, characteristicId)
                ?: return@async callback(invalidIdentifiersError(serviceId, characteristicId))
            val link = links[deviceId] ?: return@async callback(notConnectedError(deviceId))
            link.unsubscribe(key, callback)
        }
    }

    override fun isSubscribedToCharacteristic(deviceId: String, serviceId: String, characteristicId: String): Boolean =
        sync(false) {
            val key = CharacteristicKey(UUID.fromString(serviceId), UUID.fromString(characteristicId))
            links[deviceId]?.isSubscribed(key) == true
        }

    // Bluetooth state management

    /** Completes once Android's enable dialog was requested, not when the user answered it. */
    override fun requestBluetoothEnable(callback: (error: BleError?) -> Unit) {
        async(callback) {
            val bluetooth = bluetooth() ?: return@async callback(unsupportedError())
            if (bluetooth.adapter.isEnabled) return@async callback(null)
            val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                bluetooth.context.startActivity(intent)
            } catch (e: SecurityException) {
                return@async callback(unauthorizedError("Requesting Bluetooth enable", e))
            } catch (e: ActivityNotFoundException) {
                return@async callback(bleError(BleErrorCode.BLUETOOTHSTATECHANGEFAILED, "No activity handles the Bluetooth enable request"))
            }
            callback(null)
        }
    }

    /**
     * Like ble-plx, the state reflects the adapter only. Missing runtime
     * permissions surface as BluetoothUnauthorized errors of the operations that
     * need them: granting one later changes no adapter state, so a state that
     * depended on it would go stale.
     */
    override fun state(): BLEState = sync(BLEState.UNKNOWN) {
        val bluetooth = bluetooth() ?: return@sync BLEState.UNSUPPORTED
        if (!bluetooth.context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return@sync BLEState.UNSUPPORTED
        }
        try {
            adapterStateToBleState(bluetooth.adapter.state)
        } catch (e: SecurityException) {
            BLEState.UNAUTHORIZED
        }
    }

    /** One subscriber; a new subscription replaces the previous one. */
    override fun subscribeToStateChange(stateCallback: (state: BLEState) -> Unit): OperationResult = sync(destroyedResult()) {
        this.stateCallback = stateCallback
        OperationResult(success = true, error = null)
    }

    override fun unsubscribeFromStateChange(): OperationResult = sync(destroyedResult()) {
        stateCallback = null
        OperationResult(success = true, error = null)
    }

    override fun openSettings(): Promise<Unit> {
        val promise = Promise<Unit>()
        try {
            val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            appContext?.let { ctx ->
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(intent)
                promise.resolve(Unit)
            } ?: promise.reject(Exception("Context not available"))
        } catch (e: Exception) {
            promise.reject(Exception("Error opening Bluetooth settings: ${e.message}"))
        }
        return promise
    }

    /**
     * Stops the scan (its callback gets nothing more), closes every link
     * (connected links get their disconnect event with interrupted = false),
     * fails every pending operation with BluetoothManagerDestroyed, unregisters
     * the adapter state receiver and ends the handler thread. Idempotent.
     */
    override fun destroy() {
        sync<Unit>(Unit) {
            destroyed = true
            stopActiveScan()
            links.values.toList().forEach { it.destroy() }
            bluetooth?.context?.unregisterReceiver(adapterStateReceiver)
            stateCallback = null
            // Lets the tasks posted before this one run (they see `destroyed` and
            // fail with BluetoothManagerDestroyed); delayed timeouts are dropped.
            thread.quitSafely()
        }
    }

    // Handler thread plumbing

    /**
     * Runs [block] on the handler thread, later. When the manager is destroyed,
     * [onDestroyed] gets BluetoothManagerDestroyed instead: on the handler thread
     * while it still runs, on the calling thread once it ended.
     */
    private inline fun async(crossinline onDestroyed: (BleError) -> Unit, crossinline block: () -> Unit) {
        val posted = handler.post { if (destroyed) onDestroyed(destroyedError()) else block() }
        if (!posted) onDestroyed(destroyedError())
    }

    /**
     * Runs [block] on the handler thread and returns its result, blocking the
     * caller meanwhile (inline when called on the handler thread). Exceptions
     * of [block] are rethrown to the caller. [ifDestroyed] is the result once
     * the manager is destroyed.
     */
    private fun <T> sync(ifDestroyed: T, block: () -> T): T {
        if (Looper.myLooper() === thread.looper) return if (destroyed) ifDestroyed else block()
        val task = FutureTask(Callable { if (destroyed) ifDestroyed else block() })
        if (!handler.post(task)) return ifDestroyed
        try {
            return task.get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }
    }

    private fun destroyedResult() = OperationResult(success = false, error = destroyedError().message)

    /**
     * The adapter, resolved on first use (registering the adapter state receiver
     * then). Null when the device has no Bluetooth adapter, or no app context
     * could be found.
     */
    private fun bluetooth(): Bluetooth? {
        bluetooth?.let { return it }
        val context = appContext ?: currentApplication()?.also { setContext(it) } ?: return null
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter ?: return null
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Not exported: the system's broadcasts still arrive, other apps' don't.
            context.registerReceiver(adapterStateReceiver, filter, null, handler, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(adapterStateReceiver, filter, null, handler)
        }
        return Bluetooth(context, adapter).also { bluetooth = it }
    }

    /** The Application via ActivityThread, for when BleNitroPackage hasn't set the context. */
    @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
    private fun currentApplication(): Context? = try {
        Class.forName("android.app.ActivityThread").getMethod("currentApplication").invoke(null) as? Context
    } catch (e: ReflectiveOperationException) {
        Log.e(TAG, "No app context: BleNitroPackage didn't set one and ActivityThread.currentApplication() is unavailable", e)
        null
    }

    /**
     * Bluetooth turning off drops every link (pending operations fail, the
     * gatts are closed, connected links get their disconnect event with
     * interrupted = true) and ends the scan with BluetoothPoweredOff.
     */
    private fun onAdapterStateChanged(adapterState: Int) {
        if (destroyed) return
        stateCallback?.invoke(adapterStateToBleState(adapterState))
        if (adapterState != BluetoothAdapter.STATE_TURNING_OFF && adapterState != BluetoothAdapter.STATE_OFF) return
        scan?.let { active ->
            scan = null
            active.callback(null, bleError(BleErrorCode.BLUETOOTHPOWEREDOFF, "The scan stopped: Bluetooth turned off"))
        }
        links.values.toList().forEach { it.onBluetoothOff() }
    }

    // Scanning internals

    /**
     * Scan rules:
     * - one scan at a time; starting one replaces the running one
     * - a scan that can't start reports why through its callback: Bluetooth off
     *   or missing, permission missing, location services off where Android then
     *   delivers no results, an invalid service UUID, Android's start throttle,
     *   or the OS's scan error code
     * - allowDuplicates false: each device is reported once per scan
     * - rssiThreshold: weaker results are dropped; absent, nothing is
     */
    private fun beginScan(filter: ScanFilter, callback: (device: BLEDevice?, error: BleError?) -> Unit) {
        stopActiveScan()
        val bluetooth = bluetooth() ?: return callback(null, unsupportedError())
        if (!bluetooth.adapter.isEnabled) return callback(null, poweredOffError("scan"))
        missingScanPermission(bluetooth.context)?.let { permission ->
            return callback(null, bleError(BleErrorCode.BLUETOOTHUNAUTHORIZED, "Cannot scan: $permission is not granted"))
        }
        if (locationServicesRequired(bluetooth.context) && !locationServicesEnabled(bluetooth.context)) {
            return callback(
                null,
                bleError(BleErrorCode.LOCATIONSERVICESDISABLED, "Cannot scan: location services are off, and Android delivers no scan results to this app without them"),
            )
        }
        val serviceUuids = try {
            filter.serviceUUIDs.map { ParcelUuid.fromString(it) }
        } catch (e: IllegalArgumentException) {
            return callback(null, invalidIdentifiersError(*filter.serviceUUIDs))
        }
        // Null while the adapter is not on.
        val scanner = bluetooth.adapter.bluetoothLeScanner ?: return callback(null, poweredOffError("scan"))
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val wait = scanThrottle.delayBeforeNextStart(now)
            if (wait > 0) {
                return callback(null, bleError(BleErrorCode.SCANSTARTFAILED, "Cannot scan: Android allows 5 scan starts per 30 s; retry in $wait ms"))
            }
        }
        val active = ActiveScan(filter, callback)
        try {
            scanner.startScan(scanFilters(serviceUuids), scanSettings(filter.androidScanMode), active.osCallback)
        } catch (e: SecurityException) {
            return callback(null, unauthorizedError("Scanning", e))
        } catch (e: IllegalStateException) {
            // BluetoothLeScanner's answer when the adapter turned off since the check above.
            return callback(null, poweredOffError("scan"))
        }
        scanThrottle.recordStart(now)
        scan = active
    }

    /** Stops the running scan; returns whether one was running. */
    private fun stopActiveScan(): Boolean {
        val active = scan ?: return false
        scan = null
        val adapter = bluetooth?.adapter ?: return true
        // While the adapter is not on, the OS has stopped every scan already and
        // BluetoothLeScanner refuses calls.
        if (adapter.state != BluetoothAdapter.STATE_ON) return true
        try {
            adapter.bluetoothLeScanner?.stopScan(active.osCallback)
        } catch (e: IllegalStateException) {
            Log.i(TAG, "Bluetooth turned off while the scan stopped; the OS ended the scan itself")
        }
        return true
    }

    private fun scanFilters(serviceUuids: List<ParcelUuid>): List<android.bluetooth.le.ScanFilter> =
        if (serviceUuids.isEmpty()) {
            // An empty filter matches every device.
            listOf(android.bluetooth.le.ScanFilter.Builder().build())
        } else {
            serviceUuids.map { android.bluetooth.le.ScanFilter.Builder().setServiceUuid(it).build() }
        }

    private fun scanSettings(mode: AndroidScanMode): ScanSettings = ScanSettings.Builder()
        .setScanMode(
            when (mode) {
                AndroidScanMode.LOWLATENCY -> ScanSettings.SCAN_MODE_LOW_LATENCY
                AndroidScanMode.LOWPOWER -> ScanSettings.SCAN_MODE_LOW_POWER
                AndroidScanMode.BALANCED -> ScanSettings.SCAN_MODE_BALANCED
                AndroidScanMode.OPPORTUNISTIC -> ScanSettings.SCAN_MODE_OPPORTUNISTIC
            }
        )
        // Every advertisement, each reported at once: duplicates are filtered here.
        .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .setReportDelay(0)
        .build()

    /** One startScan call; results of a stopped or replaced scan are recognized by identity and dropped. */
    private inner class ActiveScan(
        private val filter: ScanFilter,
        val callback: (device: BLEDevice?, error: BleError?) -> Unit,
    ) {
        private val reported = HashSet<String>()

        // The OS calls these on the main thread.
        val osCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post { if (scan === this@ActiveScan) onResult(result) }
            }

            override fun onScanFailed(errorCode: Int) {
                handler.post {
                    if (scan === this@ActiveScan) {
                        scan = null
                        callback(null, scanFailedError(errorCode))
                    }
                }
            }
        }

        private fun onResult(result: ScanResult) {
            val threshold = filter.rssiThreshold
            if (threshold != null && result.rssi < threshold) return
            if (!filter.allowDuplicates && !reported.add(result.device.address)) return
            callback(result.toBLEDevice(), null)
        }
    }

    private fun ScanResult.toBLEDevice(): BLEDevice {
        val record = scanRecord
        val manufacturerData = record?.manufacturerSpecificData
        val manufacturerEntries = if (manufacturerData == null) {
            emptyArray()
        } else {
            // Company identifier (decimal) and the payload after it.
            Array(manufacturerData.size()) { i ->
                ManufacturerDataEntry(id = manufacturerData.keyAt(i).toString(), data = ArrayBuffer.copy(manufacturerData.valueAt(i)))
            }
        }
        val serviceEntries = record?.serviceData?.map { (uuid, data) ->
            ServiceDataEntry(uuid = uuid.toString(), data = ArrayBuffer.copy(data))
        }?.toTypedArray() ?: emptyArray()
        return BLEDevice(
            id = device.address,
            name = deviceName(device) ?: "",
            rssi = rssi.toDouble(),
            manufacturerData = ManufacturerData(companyIdentifiers = manufacturerEntries),
            serviceData = ServiceData(services = serviceEntries),
            serviceUUIDs = record?.serviceUuids?.map { it.toString() }?.toTypedArray() ?: emptyArray(),
            // Before API 26 Android doesn't tell; legacy advertisements are mostly connectable.
            isConnectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) isConnectable else true,
            isConnected = false,
        )
    }

    /** BluetoothDevice.getName(), as ble-plx reports it; null when unknown or without BLUETOOTH_CONNECT (API 31+). */
    private fun deviceName(device: BluetoothDevice): String? = try {
        device.name
    } catch (e: SecurityException) {
        null
    }

    /**
     * The runtime permission scanning needs that isn't granted, if any; the sets
     * RxAndroidBle checks, by [effectiveSdk]: BLUETOOTH_SCAN from API 31, plus
     * fine location unless BLUETOOTH_SCAN is declared neverForLocation; fine
     * location on API 29-30; fine or coarse location before. Without them a scan
     * fails or runs without ever delivering a result.
     */
    private fun missingScanPermission(context: Context): String? {
        // Every inner list must have one granted permission.
        val required = when {
            effectiveSdk(context) >= Build.VERSION_CODES.S -> if (scanNeverForLocation(context)) {
                listOf(listOf(Manifest.permission.BLUETOOTH_SCAN))
            } else {
                listOf(listOf(Manifest.permission.BLUETOOTH_SCAN), listOf(Manifest.permission.ACCESS_FINE_LOCATION))
            }
            effectiveSdk(context) >= Build.VERSION_CODES.Q -> listOf(listOf(Manifest.permission.ACCESS_FINE_LOCATION))
            else -> listOf(listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }
        val missing = required.firstOrNull { anyOf ->
            anyOf.none { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
        }
        return missing?.joinToString(" or ")
    }

    /**
     * Whether Android delivers scan results only while location services are on
     * (RxAndroidBle's LocationServicesStatus): always before API 31 (except on
     * Wear OS), from API 31 unless BLUETOOTH_SCAN is declared neverForLocation.
     */
    private fun locationServicesRequired(context: Context): Boolean {
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)) return false
        return !scanNeverForLocation(context)
    }

    /**
     * Whether the app (API 31+, targeting 31+) declares BLUETOOTH_SCAN with
     * usesPermissionFlags="neverForLocation". Read once from the manifest.
     */
    @Suppress("DEPRECATION")
    private fun scanNeverForLocation(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || context.applicationInfo.targetSdkVersion < Build.VERSION_CODES.S) return false
        scanPermissionNeverForLocation?.let { return it }
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        val index = info.requestedPermissions?.indexOf(Manifest.permission.BLUETOOTH_SCAN) ?: -1
        val flags = info.requestedPermissionsFlags
        val neverForLocation = index >= 0 && flags != null &&
            (flags[index] and PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0
        scanPermissionNeverForLocation = neverForLocation
        return neverForLocation
    }

    private fun locationServicesEnabled(context: Context): Boolean =
        LocationManagerCompat.isLocationEnabled(context.getSystemService(Context.LOCATION_SERVICE) as LocationManager)

    /** The API level whose permission model applies: the device's, capped by the app's target. */
    private fun effectiveSdk(context: Context): Int = min(Build.VERSION.SDK_INT, context.applicationInfo.targetSdkVersion)

    /** Parses a characteristic's UUIDs; null when either isn't a UUID. */
    private fun characteristicKey(serviceId: String, characteristicId: String): CharacteristicKey? = try {
        CharacteristicKey(UUID.fromString(serviceId), UUID.fromString(characteristicId))
    } catch (e: IllegalArgumentException) {
        null
    }
}
