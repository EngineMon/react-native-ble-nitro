import Foundation
import CoreBluetooth
import NitroModules
import UIKit

/**
 * iOS implementation of NativeBleNitro (src/specs/NativeBleNitro.nitro.ts) on
 * CoreBluetooth: the HybridObject facade over BleCore, which holds all BLE state and
 * logic. Android's counterpart is BleNitroBleManager.kt.
 *
 * What it does, on the caller's thread, before anything reaches the manager's queue:
 * - Validates and canonicalizes inputs. Device ids parse through UUID, which also gives
 *   the canonical uppercase form (methods accept any letter case). Service and
 *   characteristic UUIDs parse through GattUuid.parse, which accepts exactly the forms
 *   NativeBleNitro.nitro.ts, section "UUIDs" lists. The connect timeout and the MTU go through
 *   GattRules, so no Double is ever converted to an integer unchecked (Swift traps on
 *   NaN, infinity and out-of-range values), and only a valid ConnectDeadline goes below.
 * - Copies write data: the caller may reuse its buffer as soon as the call returns (a C++
 *   caller passes a view of its own memory).
 * - Allocates subscription and listener ids (IdSource) and hands the registration to the
 *   core before returning the id, so any later unsubscribe, from any thread, runs after
 *   it on the core's FIFO queue.
 * - Wraps each callback exactly once through the manager's CallbackGate into the core's
 *   Reply (one result), Once (one event), Listener (repeating events) or ScanStartFailure:
 *   nothing below this class holds a raw callback, so every delivery rule (at most once,
 *   only on the queue) holds for every callback. Once destroy() was called, listeners and
 *   events are silent, and completions still fire, with BluetoothManagerDestroyed
 *   (NativeBleNitro.nitro.ts, section "After destroy()").
 *
 * Rejected input never fails inline: it goes through BleCore.reject, which reports it
 * from the queue like every callback (NativeBleNitro.nitro.ts, section "Threading"), and with
 * BluetoothManagerDestroyed instead once the manager was destroyed. Synchronous getters
 * return their empty value (false, [], undefined) for input that doesn't parse; they
 * never throw.
 *
 * Lifetime: closures made here capture the core and the caller's callbacks, never this
 * object. Nitro calls dispose() only when JS calls it by hand, so deinit (the last JS or
 * C++ reference went away, e.g. on a JS reload) destroys the core too: the connections
 * and the central are released and every pending completion fails with
 * BluetoothManagerDestroyed instead of never being called.
 */
public class BleNitroBleManager: HybridNativeBleNitroSpec {

    private let core: BleCore
    /// The one gate every callback of this manager is wrapped through; the core holds the same one.
    private let gate: CallbackGate

    /**
     * With BLENitroLazyInit in Info.plist the central (and with it the permission prompt
     * and state restoration) waits for the first call that needs it, or iosLazyInit().
     */
    public init(restoreStateIdentifier: String? = nil, restoreStateCallback: (([BLEDevice]) -> Void)? = nil) {
        let lazyInitEnabled = Bundle.main.object(forInfoDictionaryKey: "BLENitroLazyInit") as? Bool ?? false
        if lazyInitEnabled && restoreStateIdentifier != nil {
            bleLog("Warning: lazyInit is enabled with restoreStateIdentifier. State restoration will be delayed until first BLE API call.")
        }
        let gate = CallbackGate()
        self.gate = gate
        core = BleCore(
            restoreIdentifier: restoreStateIdentifier,
            restoreCallback: restoreStateCallback.map { gate.event($0) },
            gate: gate,
            createCentral: !lazyInitEnabled
        )
        super.init()
    }

    deinit {
        core.destroy()
    }

    /// Nitro's manual disposal (JS `dispose()`): the same as destroy().
    public func dispose() {
        core.destroy()
    }

    /// Wraps an OperationCallback (no result value) once.
    private func operationReply(_ callback: @escaping (BleError?) -> Void) -> Reply<Void, BleError> {
        return gate.reply { error, _ in callback(error) }
    }

    /// The device a request names; nil, after rejecting the request through `failing` with InvalidIdentifiers, when its id doesn't parse.
    private func device<F: Failable>(_ deviceId: String, failing: F) -> UUID? where F.Failure == BleError {
        guard let id = UUID(uuidString: deviceId) else {
            core.reject(failing, invalidIdentifiersError(deviceId))
            return nil
        }
        return id
    }

    /**
     * The device and characteristic a request names; nil, after rejecting the request
     * through `failing` with InvalidIdentifiers, when one of the ids doesn't parse.
     */
    private func characteristic<F: Failable>(
        _ deviceId: String,
        _ serviceId: String,
        _ characteristicId: String,
        failing: F
    ) -> (device: UUID, key: CharacteristicKey)? where F.Failure == BleError {
        guard let target = Self.parsedCharacteristic(deviceId, serviceId, characteristicId) else {
            core.reject(failing, invalidIdentifiersError(deviceId, serviceId, characteristicId))
            return nil
        }
        return target
    }

    /**
     * The device and characteristic three ids name; nil when one doesn't parse. Keyed by
     * service and characteristic UUID: two services may have characteristics with the same
     * UUID.
     */
    private static func parsedCharacteristic(_ deviceId: String, _ serviceId: String, _ characteristicId: String) -> (device: UUID, key: CharacteristicKey)? {
        guard let id = UUID(uuidString: deviceId),
              let service = GattUuid.parse(serviceId),
              let characteristic = GattUuid.parse(characteristicId) else { return nil }
        return (id, CharacteristicKey(service: service, characteristic: characteristic))
    }

    /**
     * A listener or subscription id as the core knows it: a positive integer
     * (NativeBleNitro.nitro.ts: ids are positive integers), nil for anything else. Such a
     * number can't be an id this manager handed out, so it names no registration; the
     * same rule as Android's `idOf`.
     */
    private static func registrationId(_ id: Double) -> Int64? {
        guard let integer = Int64(exactly: id), integer > 0 else { return nil }
        return integer
    }

    // MARK: - Initialization and state restoration

    /**
     * The CBCentralManager restore identifier. It takes effect when the central is created
     * (right after init, or at the first call with lazy init); setting it later changes
     * nothing (NativeBleNitro.nitro.ts, restoreStateIdentifier).
     */
    public var restoreStateIdentifier: String? {
        get { return core.restoreStateIdentifier }
        set { core.restoreStateIdentifier = newValue }
    }

    public func iosLazyInit() throws {
        core.lazyInit()
    }

    /// The restored peripherals reach `callback` once; a report made before it was registered waits for it.
    public func setRestoreStateCallback(callback: @escaping ([BLEDevice]) -> Void) throws {
        core.setRestoreCallback(gate.event(callback))
    }

    // MARK: - Bluetooth state

    /// Unknown once destroyed.
    public func state() throws -> BLEState {
        return core.state()
    }

    /// iOS doesn't let apps turn Bluetooth on: fails with BluetoothStateChangeFailed (BluetoothManagerDestroyed once destroyed).
    public func requestBluetoothEnable(callback: @escaping (BleError?) -> Void) throws {
        core.requestBluetoothEnable(operationReply(callback))
    }

    public func subscribeToStateChange(stateCallback: @escaping (BLEState) -> Void) throws -> Double {
        let id = IdSource.next()
        core.addStateObserver(id: id, gate.listener(stateCallback))
        return Double(id)
    }

    /// An id that isn't one this manager hands out names no listener: nothing to remove.
    public func unsubscribeFromStateChange(listenerId: Double) throws {
        if let id = Self.registrationId(listenerId) {
            core.removeStateObserver(id: id)
        }
    }

    public func subscribeToConnectionEvents(callback: @escaping (ConnectionEvent) -> Void) throws -> Double {
        let id = IdSource.next()
        core.addConnectionObserver(id: id, gate.listener(callback))
        return Double(id)
    }

    /// An id that isn't one this manager hands out names no listener: nothing to remove.
    public func unsubscribeFromConnectionEvents(listenerId: Double) throws {
        if let id = Self.registrationId(listenerId) {
            core.removeConnectionObserver(id: id)
        }
    }

    public func openSettings() throws -> Promise<Void> {
        return Promise.async {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                // Ask the system to open that URL.
                await UIApplication.shared.open(url)
            }
        }
    }

    // MARK: - Scanning

    /**
     * Failures are reported through `callback` (device nil), never thrown. An invalid
     * service UUID is reported to this callback only and leaves a running scan alone
     * (NativeBleNitro.nitro.ts, startScan).
     */
    public func startScan(filter: ScanFilter, callback: @escaping (BLEDevice?, BleError?) -> Void) throws {
        // One callback, three roles (see ScanCallbacks), as on Android.
        let callbacks = ScanCallbacks(
            onResult: gate.listener { device in callback(device, nil) },
            startFailure: gate.scanStartFailure { error in callback(nil, error) },
            ended: gate.scanEnded { error in callback(nil, error) }
        )
        var services: [CBUUID] = []
        for serviceId in filter.serviceUUIDs {
            guard let service = GattUuid.parse(serviceId) else {
                return core.reject(callbacks.startFailure, invalidIdentifiersError(serviceId))
            }
            services.append(service)
        }
        core.startScan(
            services: services,
            rssiThreshold: filter.rssiThreshold,
            allowDuplicates: filter.allowDuplicates,
            callbacks: callbacks
        )
    }

    /// Returns whether a scan was running; its callback gets nothing more.
    public func stopScan() throws -> Bool {
        return core.stopScan()
    }

    public func isScanning() throws -> Bool {
        return core.isScanning()
    }

    // MARK: - Devices and connections

    /// See ServiceFilter for what `services` means, the same on both platforms.
    public func getConnectedDevices(services: [String]) throws -> [BLEDevice] {
        return core.connectedDevices(ServiceFilter(services: services))
    }

    /**
     * ConnectOptions.timeoutMs goes through GattRules.connectDeadline: absent or +∞ means
     * no deadline; NaN, 0 or negative fails the connect with OperationStartFailed.
     * autoConnect and refreshGatt are Android options. See BleCore.connect for the rest.
     */
    public func connect(
        deviceId: String,
        options: ConnectOptions,
        callback: @escaping (BleError?) -> Void,
        disconnectCallback: ((String, Bool, BleError?) -> Void)?
    ) throws {
        let reply = operationReply(callback)
        let onDisconnect = disconnectCallback.map { notify in
            gate.event { (event: ConnectionEvent) in notify(event.deviceId, event.interrupted, event.error) }
        }
        guard let id = device(deviceId, failing: reply) else { return }
        guard let deadline = GattRules.connectDeadline(timeoutMs: options.timeoutMs) else {
            return core.reject(reply, invalidConnectTimeoutError(deviceId: id.uuidString, timeoutMs: options.timeoutMs))
        }
        core.connect(id, deadline: deadline, reply: reply, onDisconnect: onDisconnect)
    }

    public func disconnect(deviceId: String, callback: @escaping (BleError?) -> Void) throws {
        let reply = operationReply(callback)
        guard let id = device(deviceId, failing: reply) else { return }
        core.disconnect(id, reply: reply)
    }

    public func isConnected(deviceId: String) throws -> Bool {
        guard let id = UUID(uuidString: deviceId) else { return false }
        return core.isConnected(id)
    }

    /**
     * maximumWriteValueLength(.withoutResponse) + 3: CoreBluetooth exposes no ATT MTU,
     * only the longest Write Command value, which is ATT_MTU − 3 (Bluetooth Core
     * Specification Vol 3 Part F §3.4.5.3).
     */
    public func getMtu(deviceId: String) throws -> Double? {
        guard let id = UUID(uuidString: deviceId) else { return nil }
        return core.mtu(id)
    }

    /**
     * `mtu` must be an integer in 23...517 (DeviceMTUChangeFailed otherwise, as on
     * Android) even though iOS negotiates the MTU by itself: the request completes with the
     * MTU in effect (getMtu). See BleCore.requestMtu.
     */
    public func requestMTU(deviceId: String, mtu: Double, callback: @escaping (BleError?, Double?) -> Void) throws {
        let reply = gate.reply(callback)
        guard let id = device(deviceId, failing: reply) else { return }
        core.requestMtu(id, mtu: mtu, reply: reply)
    }

    /// Android only: completes without error while the link is up, DeviceNotConnected otherwise.
    public func requestConnectionPriority(
        deviceId: String,
        androidConnectionPriority: AndroidConnectionPriority,
        callback: @escaping (BleError?) -> Void
    ) throws {
        let reply = operationReply(callback)
        guard let id = device(deviceId, failing: reply) else { return }
        core.requestConnectionPriority(id, reply: reply)
    }

    public func readRSSI(deviceId: String, callback: @escaping (BleError?, Double?) -> Void) throws {
        let reply = gate.reply(callback)
        guard let id = device(deviceId, failing: reply) else { return }
        core.readRSSI(id, reply: reply)
    }

    // MARK: - GATT

    /// Discovers the services and their characteristics.
    public func discoverServices(deviceId: String, callback: @escaping (BleError?) -> Void) throws {
        let reply = operationReply(callback)
        guard let id = device(deviceId, failing: reply) else { return }
        core.discoverServices(id, reply: reply)
    }

    /// Full lowercase 128-bit UUIDs; empty when not connected or not discovered.
    public func getServices(deviceId: String) throws -> [String] {
        guard let id = UUID(uuidString: deviceId) else { return [] }
        return core.services(id)
    }

    /// Full lowercase 128-bit UUIDs; empty when not connected, not discovered, or an id doesn't parse.
    public func getCharacteristics(deviceId: String, serviceId: String) throws -> [String] {
        guard let id = UUID(uuidString: deviceId), let service = GattUuid.parse(serviceId) else { return [] }
        return core.characteristics(id, service: service)
    }

    public func getCharacteristicProperties(deviceId: String, serviceId: String, characteristicId: String) throws -> CharacteristicProperties? {
        guard let target = Self.parsedCharacteristic(deviceId, serviceId, characteristicId) else { return nil }
        return core.characteristicProperties(target.device, key: target.key)
    }

    public func readCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: @escaping (BleError?, ArrayBuffer?) -> Void
    ) throws {
        let reply = gate.reply(callback)
        guard let target = characteristic(deviceId, serviceId, characteristicId, failing: reply) else { return }
        core.read(target.device, key: target.key, reply: reply)
    }

    /// The bytes are copied before this returns: the caller may reuse or change its buffer right away.
    public func writeCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        data: ArrayBuffer,
        withResponse: Bool,
        callback: @escaping (BleError?, ArrayBuffer?) -> Void
    ) throws {
        let reply = gate.reply(callback)
        guard let target = characteristic(deviceId, serviceId, characteristicId, failing: reply) else { return }
        let bytes = Data(bytes: data.data, count: data.size)
        core.write(target.device, key: target.key, data: bytes, withResponse: withResponse, reply: reply)
    }

    /**
     * Returns the subscription's id at once; the subscription itself is made on the queue,
     * ahead of anything requested after this returns. Each value is copied into a buffer
     * of its own per subscriber, valid after the callback returns.
     */
    public func subscribeToCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        updateCallback: @escaping (ArrayBuffer) -> Void,
        completionCallback: @escaping (BleError?) -> Void,
        endedCallback: ((BleError) -> Void)?
    ) throws -> Double {
        let id = IdSource.next()
        let completion = operationReply(completionCallback)
        let onValue: Listener<Data> = gate.listener { data in updateCallback(ArrayBuffer.copying(data)) }
        let onEnded: Once<BleError>? = endedCallback.map { gate.event($0) }
        if let target = characteristic(deviceId, serviceId, characteristicId, failing: completion) {
            core.subscribe(id, device: target.device, key: target.key, onValue: onValue, completion: completion, onEnded: onEnded)
        }
        return Double(id)
    }

    /// An id that isn't one this manager hands out names no subscription: the unsubscribe succeeds, like one of a subscription that already ended.
    public func unsubscribeFromCharacteristic(subscriptionId: Double, callback: @escaping (BleError?) -> Void) throws {
        let reply = operationReply(callback)
        guard let id = Self.registrationId(subscriptionId) else {
            return core.complete(reply)
        }
        core.unsubscribe(id, reply: reply)
    }

    /// Whether an active subscription of this manager (completed, not ended) exists on the characteristic; see BleCore.isSubscribed.
    public func isSubscribedToCharacteristic(deviceId: String, serviceId: String, characteristicId: String) throws -> Bool {
        guard let target = Self.parsedCharacteristic(deviceId, serviceId, characteristicId) else { return false }
        return core.isSubscribed(target.device, key: target.key)
    }

    // MARK: - Destroy

    /**
     * Silences every listener, stops the scan, closes every link silently, fails everything
     * pending with BluetoothManagerDestroyed and releases the central (see
     * BleCore.destroy). Returns once no listener can still be running (a C++ caller may
     * then free its listener state), without waiting for the teardown: the completions it
     * fails run on the queue, never on the caller's thread.
     */
    public func destroy() throws {
        core.destroy()
    }
}
