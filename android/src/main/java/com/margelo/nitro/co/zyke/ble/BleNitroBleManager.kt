package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.provider.Settings
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise

/**
 * Android implementation of the BLE Nitro Module; the behavior contract is
 * NativeBleNitro.nitro.ts.
 *
 * The facade holds no BLE state (that is [BleCore], on the manager's own
 * thread) and does on the calling thread only what must happen there:
 * - Canonicalizes and validates inputs. Device ids become uppercase (the
 *   canonical id, the form BluetoothAdapter.checkBluetoothAddress accepts).
 *   UUIDs are parsed by [GattUuid] (NativeBleNitro.nitro.ts, section
 *   "UUIDs"). A call whose input doesn't parse fails asynchronously with
 *   InvalidIdentifiers ([BleCore.reject]); a getter returns its empty value.
 * - Copies a write's bytes: a buffer from JS, or a non-owning view from C++,
 *   is valid only during this call.
 * - Allocates subscription and listener ids ([IdSource]) and posts the
 *   registration before returning the id, so a later call with that id runs
 *   after it on the FIFO executor.
 * - Wraps every user callback exactly once through the [gate], into the type
 *   of its role; nothing below accepts anything else (see [CallbackGate]).
 */
class BleNitroBleManager : HybridNativeBleNitroSpec() {
    private val gate = CallbackGate()
    private val core = BleCore(gate)

    // iOS only (CoreBluetooth state restoration): kept as set, otherwise unused on Android.
    override var restoreStateIdentifier: String? = null

    override fun setRestoreStateCallback(callback: (restoredPeripherals: Array<BLEDevice>) -> Unit) {
        // iOS only; Android has no state restoration.
    }

    override fun iosLazyInit() {
        // iOS only.
    }

    // Scanning

    override fun startScan(filter: ScanFilter, callback: (device: BLEDevice?, error: BleError?) -> Unit) {
        val callbacks = ScanCallbacks(
            onResult = gate.listener { device -> callback(device, null) },
            startFailure = gate.scanStartFailure { error -> callback(null, error) },
            ended = gate.scanEnded { error -> callback(null, error) },
        )
        val serviceUuids = filter.serviceUUIDs.map { uuid ->
            GattUuid.parse(uuid) ?: return core.reject(callbacks.startFailure, invalidIdentifiersError(uuid))
        }
        core.startScan(serviceUuids, filter, callbacks)
    }

    override fun stopScan(): Boolean = core.stopScan()

    override fun isScanning(): Boolean = core.isScanning()

    override fun getConnectedDevices(services: Array<String>): Array<BLEDevice> = core.getConnectedDevices(
        if (services.isEmpty()) ServiceFilter.Any else ServiceFilter.AnyOf(services.mapNotNull(GattUuid::parse))
    )

    // Connection management

    override fun connect(
        deviceId: String,
        options: ConnectOptions,
        callback: (error: BleError?) -> Unit,
        disconnectCallback: ((deviceId: String, interrupted: Boolean, error: BleError?) -> Unit)?,
    ) {
        val reply = gate.reply<Unit> { error, _ -> callback(error) }
        val onDisconnect = disconnectCallback?.let { onDown ->
            gate.event<ConnectionEvent> { event -> onDown(event.deviceId, event.interrupted, event.error) }
        }
        withDevice(deviceId, reply) { id ->
            val deadline = GattRules.connectDeadline(options.timeoutMs)
                ?: return core.reject(reply, invalidConnectTimeoutError(id, options.timeoutMs))
            core.connect(id, options.autoConnect == true, options.refreshGatt == true, deadline, reply, onDisconnect)
        }
    }

    override fun disconnect(deviceId: String, callback: (error: BleError?) -> Unit) {
        val reply = gate.reply<Unit> { error, _ -> callback(error) }
        withDevice(deviceId, reply) { id -> core.disconnect(id, reply) }
    }

    override fun isConnected(deviceId: String): Boolean {
        val id = canonicalDeviceId(deviceId) ?: return false
        return core.isConnected(id)
    }

    override fun getMtu(deviceId: String): Double? {
        val id = canonicalDeviceId(deviceId) ?: return null
        return core.mtu(id)
    }

    override fun requestMTU(deviceId: String, mtu: Double, callback: (error: BleError?, mtu: Double?) -> Unit) {
        val reply = gate.reply<Double> { error, value -> callback(error, value) }
        withDevice(deviceId, reply) { id -> core.requestMtu(id, mtu, reply) }
    }

    override fun requestConnectionPriority(
        deviceId: String,
        androidConnectionPriority: AndroidConnectionPriority,
        callback: (error: BleError?) -> Unit,
    ) {
        val reply = gate.reply<Unit> { error, _ -> callback(error) }
        withDevice(deviceId, reply) { id -> core.requestConnectionPriority(id, androidConnectionPriority, reply) }
    }

    override fun readRSSI(deviceId: String, callback: (error: BleError?, rssi: Double?) -> Unit) {
        val reply = gate.reply<Double> { error, value -> callback(error, value) }
        withDevice(deviceId, reply) { id -> core.readRssi(id, reply) }
    }

    // Service discovery

    override fun discoverServices(deviceId: String, callback: (error: BleError?) -> Unit) {
        val reply = gate.reply<Unit> { error, _ -> callback(error) }
        withDevice(deviceId, reply) { id -> core.discoverServices(id, reply) }
    }

    override fun getServices(deviceId: String): Array<String> {
        val id = canonicalDeviceId(deviceId) ?: return emptyArray()
        return core.services(id)
    }

    override fun getCharacteristics(deviceId: String, serviceId: String): Array<String> {
        val id = canonicalDeviceId(deviceId) ?: return emptyArray()
        val service = GattUuid.parse(serviceId) ?: return emptyArray()
        return core.characteristics(id, service)
    }

    override fun getCharacteristicProperties(deviceId: String, serviceId: String, characteristicId: String): CharacteristicProperties? {
        val id = canonicalDeviceId(deviceId) ?: return null
        val key = characteristicKey(serviceId, characteristicId) ?: return null
        return core.characteristicProperties(id, key)
    }

    // Characteristic operations

    override fun readCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: (error: BleError?, data: ArrayBuffer?) -> Unit,
    ) {
        val reply = gate.reply<ArrayBuffer> { error, data -> callback(error, data) }
        withCharacteristic(deviceId, serviceId, characteristicId, reply) { id, key -> core.read(id, key, reply) }
    }

    override fun writeCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        data: ArrayBuffer,
        withResponse: Boolean,
        callback: (error: BleError?, responseData: ArrayBuffer?) -> Unit,
    ) {
        // Copied first, on the calling thread: a buffer from JS (or a
        // non-owning one from C++) is valid only during this call, and the
        // caller may reuse it once the call returns.
        val source = data.getBuffer(false).duplicate()
        // Buffer.rewind(): ByteBuffer's covariant override is newer than minSdk.
        (source as java.nio.Buffer).rewind()
        val value = ByteArray(source.remaining())
        source.get(value)
        val reply = gate.reply<ArrayBuffer> { error, written -> callback(error, written) }
        withCharacteristic(deviceId, serviceId, characteristicId, reply) { id, key ->
            core.write(id, key, value, withResponse, reply)
        }
    }

    override fun subscribeToCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        updateCallback: (data: ArrayBuffer) -> Unit,
        completionCallback: (error: BleError?) -> Unit,
        endedCallback: ((error: BleError) -> Unit)?,
    ): Double {
        val subscriptionId = IdSource.next()
        val onValue = gate.listener(updateCallback)
        val completion = gate.reply<Unit> { error, _ -> completionCallback(error) }
        val onEnded = endedCallback?.let { gate.event(it) }
        withCharacteristic(deviceId, serviceId, characteristicId, completion) { id, key ->
            core.subscribe(subscriptionId, id, key, onValue, completion, onEnded)
        }
        return subscriptionId.toDouble()
    }

    override fun unsubscribeFromCharacteristic(subscriptionId: Double, callback: (error: BleError?) -> Unit) {
        val reply = gate.reply<Unit> { error, _ -> callback(error) }
        // An id that isn't one names no subscription: success, like an ended one.
        val id = idOf(subscriptionId) ?: return core.complete(reply)
        core.unsubscribe(id, reply)
    }

    override fun isSubscribedToCharacteristic(deviceId: String, serviceId: String, characteristicId: String): Boolean {
        val id = canonicalDeviceId(deviceId) ?: return false
        val key = characteristicKey(serviceId, characteristicId) ?: return false
        return core.isSubscribed(id, key)
    }

    // Bluetooth state

    override fun requestBluetoothEnable(callback: (error: BleError?) -> Unit) {
        core.requestBluetoothEnable(gate.reply { error, _ -> callback(error) })
    }

    override fun state(): BLEState = core.state()

    override fun subscribeToStateChange(stateCallback: (state: BLEState) -> Unit): Double {
        val listenerId = IdSource.next()
        core.addStateObserver(listenerId, gate.listener(stateCallback))
        return listenerId.toDouble()
    }

    override fun unsubscribeFromStateChange(listenerId: Double) {
        idOf(listenerId)?.let { core.removeStateObserver(it) }
    }

    override fun subscribeToConnectionEvents(callback: (event: ConnectionEvent) -> Unit): Double {
        val listenerId = IdSource.next()
        core.addConnectionObserver(listenerId, gate.listener(callback))
        return listenerId.toDouble()
    }

    override fun unsubscribeFromConnectionEvents(listenerId: Double) {
        idOf(listenerId)?.let { core.removeConnectionObserver(it) }
    }

    override fun openSettings(): Promise<Unit> {
        val promise = Promise<Unit>()
        val context = BleNitroLifecycle.appContext()
        if (context == null) {
            promise.reject(Exception("Context not available"))
            return promise
        }
        try {
            context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            promise.resolve(Unit)
        } catch (e: Exception) {
            promise.reject(Exception("Error opening Bluetooth settings: ${e.message}"))
        }
        return promise
    }

    /** See [BleCore.destroy]. Idempotent. */
    override fun destroy() = core.destroy()

    /**
     * JS's `dispose()` on the HybridObject. Nitro calls it only when JS calls
     * it by hand (never on a reload or garbage collection; [BleNitroLifecycle]
     * covers reloads); it releases everything, like [destroy].
     */
    override fun dispose() = core.destroy()

    // Input canonicalization

    /** Runs [run] with the canonical id of [deviceId], or fails [failing] with InvalidIdentifiers. */
    private inline fun withDevice(deviceId: String, failing: Failable<BleError>, run: (id: String) -> Unit) {
        val id = canonicalDeviceId(deviceId) ?: return core.reject(failing, invalidIdentifiersError(deviceId))
        run(id)
    }

    /** [withDevice], then the characteristic's UUIDs; InvalidIdentifiers when any doesn't parse. */
    private inline fun withCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        failing: Failable<BleError>,
        run: (id: String, key: CharacteristicKey) -> Unit,
    ) {
        withDevice(deviceId, failing) { id ->
            val key = characteristicKey(serviceId, characteristicId)
                ?: return core.reject(failing, invalidIdentifiersError(serviceId, characteristicId))
            run(id, key)
        }
    }

    /** The canonical device id: the uppercase MAC address, or null when [deviceId] isn't one. */
    private fun canonicalDeviceId(deviceId: String): String? {
        val id = deviceId.uppercase()
        return if (BluetoothAdapter.checkBluetoothAddress(id)) id else null
    }

    private fun characteristicKey(serviceId: String, characteristicId: String): CharacteristicKey? {
        val service = GattUuid.parse(serviceId) ?: return null
        val characteristic = GattUuid.parse(characteristicId) ?: return null
        return CharacteristicKey(service, characteristic)
    }

    /**
     * A subscription or listener id: a positive integer ([IdSource] starts at
     * 1). Anything else (NaN, a fraction, 0, out of range) names nothing.
     */
    private fun idOf(number: Double): Long? {
        val id = number.toLong()
        return if (id >= 1 && id.toDouble() == number) id else null
    }
}
