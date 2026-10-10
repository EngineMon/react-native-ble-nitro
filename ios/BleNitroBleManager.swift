import Foundation
import CoreBluetooth
import NitroModules
import UIKit

/**
 * iOS implementation of NativeBleNitro (src/specs/NativeBleNitro.nitro.ts) on CoreBluetooth.
 *
 * Threading (spec "Threading"):
 * - One serial queue per manager owns the CBCentralManager, receives every central and
 *   peripheral delegate call, and holds all mutable state, here and in each peripheral's
 *   BlePeripheralDelegate. Nothing else touches that state.
 * - Every public method runs on it. Synchronous getters wait for it (`onQueueSync`);
 *   methods that answer through a callback hop onto it (`onQueueAsync`) and return at
 *   once, so requests run in call order.
 * - So every callback is invoked from that queue, in the order CoreBluetooth delivered the
 *   events. Callbacks created in JS hop to the JS thread (Nitro); callbacks created in C++
 *   by another native module run on the queue itself and must not block it.
 * - Nothing here runs on, or waits for, the main queue.
 */
public class BleNitroBleManager: HybridNativeBleNitroSpec {

    /// A running scan.
    private struct Scan {
        /// Nil for a scan the system restored: it runs, but its results go nowhere until
        /// startScan replaces it or stopScan ends it.
        let callback: ((BLEDevice?, BleError?) -> Void)?
        let rssiThreshold: Double?
    }

    /// State restoration's report, made once per manager (see centralDidUpdateState).
    private enum RestoredState {
        case notReported
        /// Reported before a callback was registered.
        case waitingForCallback([BLEDevice])
        case delivered
    }

    private static let destroyedError = BleError(.bluetoothmanagerdestroyed, "The BLE manager was destroyed")
    /**
     * The rssi of a device known without an advertisement (restored, or connected). The spec
     * makes rssi a number: 127 is HCI's "RSSI not available" value, which CoreBluetooth also
     * reports when it has none. Android reports the same.
     */
    private static let rssiUnavailable: Double = 127

    private let queue = DispatchQueue(label: "co.zyke.ble.nitro")
    /**
     * Present only on `queue`. A getter called from code already running there (a C++
     * callback calling back in) runs inline, where `queue.sync` would deadlock.
     */
    private let queueKey = DispatchSpecificKey<Bool>()

    private var restoreIdentifier: String?
    private var central: CBCentralManager?
    /// CBCentralManager.delegate is weak.
    private var centralDelegate: BleCentralManagerDelegate?
    /// The central was created with a restore identifier.
    private var restoresState = false
    private var destroyed = false

    private var stateCallback: ((BLEState) -> Void)?
    private var restoreCallback: (([BLEDevice]) -> Void)?
    private var restoredState = RestoredState.notReported
    private var scan: Scan?
    /**
     * Peripherals seen by scans, kept so they can be connected (CoreBluetooth needs the app
     * to retain a peripheral it uses). Bounded: every scan start drops the ones that aren't
     * connected (see startScan).
     */
    private var discovered: [String: CBPeripheral] = [:]
    /**
     * The delegate of every peripheral this manager connected or was handed (restoration,
     * a request on a peripheral the system connected), by device id. Kept as long as the
     * peripheral object is valid, so a peripheral never gets a second one: until the
     * central's state drops below poweredOff (see bluetoothBecameUnavailable) or destroy.
     * Bounded by the peripherals actually used.
     */
    private var links: [String: BlePeripheralDelegate] = [:]

    // MARK: - Initialization

    /**
     * With BLENitroLazyInit in Info.plist the central (and with it the permission prompt
     * and state restoration) waits for the first call that needs it, or iosLazyInit().
     */
    public init(restoreStateIdentifier: String? = nil, restoreStateCallback: (([BLEDevice]) -> Void)? = nil) {
        self.restoreIdentifier = restoreStateIdentifier
        self.restoreCallback = restoreStateCallback
        let lazyInitEnabled = Bundle.main.object(forInfoDictionaryKey: "BLENitroLazyInit") as? Bool ?? false
        super.init()
        queue.setSpecific(key: queueKey, value: true)
        if lazyInitEnabled && restoreStateIdentifier != nil {
            print("[BleNitro] Warning: lazyInit is enabled with restoreStateIdentifier. State restoration will be delayed until first BLE API call.")
        }
        if !lazyInitEnabled {
            onQueueAsync { [self] in _ = ensureCentralManager() }
        }
    }

    /**
     * The CBCentralManager restore identifier. It takes effect when the central is created
     * (right after init, or at the first call with lazy init); setting it later changes
     * nothing.
     */
    public var restoreStateIdentifier: String? {
        get { onQueueSync { restoreIdentifier } }
        set { onQueueSync { restoreIdentifier = newValue } }
    }

    /// Runs `work` on the queue and returns its result (synchronous getters).
    private func onQueueSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// Runs `work` on the queue after everything requested before it (callback methods).
    private func onQueueAsync(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// The central; created on first use. Nil once destroyed.
    private func ensureCentralManager() -> CBCentralManager? {
        if let central = central {
            return central
        }
        guard !destroyed else { return nil }
        var options: [String: Any] = [:]
        if let identifier = restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = identifier
        }
        let delegate = BleCentralManagerDelegate(manager: self)
        let central = CBCentralManager(delegate: delegate, queue: queue, options: options.isEmpty ? nil : options)
        self.centralDelegate = delegate
        self.central = central
        self.restoresState = restoreIdentifier != nil
        return central
    }

    /// The central if it is on; else calls `fail` with why not (destroyed, or its state) and returns nil.
    private func poweredOnCentral(else fail: (BleError) -> Void) -> CBCentralManager? {
        guard let central = ensureCentralManager() else {
            fail(Self.destroyedError)
            return nil
        }
        if let error = central.state.unavailableError {
            fail(error)
            return nil
        }
        return central
    }

    public func iosLazyInit() throws {
        onQueueAsync { [self] in _ = ensureCentralManager() }
    }

    // MARK: - Bluetooth state

    /// Unknown once destroyed.
    public func state() throws -> BLEState {
        return onQueueSync { ensureCentralManager()?.state.bleState ?? .unknown }
    }

    /// iOS doesn't let apps turn Bluetooth on: fails with BluetoothStateChangeFailed, as ble-plx's enable() does there.
    public func requestBluetoothEnable(callback: @escaping (BleError?) -> Void) throws {
        onQueueAsync {
            callback(BleError(.bluetoothstatechangefailed, "iOS does not let apps turn Bluetooth on"))
        }
    }

    /// One callback (the JS layer fans it out to its subscribers); it gets every state change.
    public func subscribeToStateChange(stateCallback: @escaping (BLEState) -> Void) throws -> OperationResult {
        return onQueueSync {
            guard ensureCentralManager() != nil else {
                return OperationResult(success: false, error: Self.destroyedError.message)
            }
            self.stateCallback = stateCallback
            return OperationResult(success: true, error: nil)
        }
    }

    public func unsubscribeFromStateChange() throws -> OperationResult {
        return onQueueSync {
            stateCallback = nil
            return OperationResult(success: true, error: nil)
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

    // MARK: - State restoration

    /**
     * The restored peripherals reach `callback` once; a report made before it was registered
     * waits for it.
     */
    public func setRestoreStateCallback(callback: @escaping ([BLEDevice]) -> Void) throws {
        onQueueAsync { [self] in
            guard !destroyed else { return }
            restoreCallback = callback
            deliverRestoredState()
        }
    }

    private func reportRestoredState(_ devices: [BLEDevice]) {
        guard case .notReported = restoredState else { return }
        restoredState = .waitingForCallback(devices)
        deliverRestoredState()
    }

    private func deliverRestoredState() {
        guard case .waitingForCallback(let devices) = restoredState, let callback = restoreCallback else { return }
        restoredState = .delivered
        callback(devices)
    }

    // MARK: - Scanning

    /**
     * Failures are reported through `callback` (device nil), never thrown (spec): invalid
     * service UUIDs, Bluetooth not on (or destroyed), and Bluetooth turning off while it
     * runs. Starting again replaces the running scan.
     */
    public func startScan(filter: ScanFilter, callback: @escaping (BLEDevice?, BleError?) -> Void) throws {
        let serviceIds = filter.serviceUUIDs
        let rssiThreshold = filter.rssiThreshold
        let allowDuplicates = filter.allowDuplicates
        onQueueAsync { [self] in
            let fail = { (error: BleError) in callback(nil, error) }
            var services: [CBUUID] = []
            for serviceId in serviceIds {
                guard let service = CBUUID.parse(serviceId) else {
                    return fail(BleError(.invalididentifiers, "Invalid service UUID \(serviceId)"))
                }
                services.append(service)
            }
            guard let central = poweredOnCentral(else: fail) else { return }
            // Keeps `discovered` bounded: what the last scan found and nobody connected is
            // dropped (a connect falls back to retrievePeripherals for it anyway).
            discovered = discovered.filter { $0.value.state != .disconnected }
            scan = Scan(callback: callback, rssiThreshold: rssiThreshold)
            central.scanForPeripherals(
                withServices: services.isEmpty ? nil : services,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
            )
        }
    }

    /// Returns true: no scan runs afterwards.
    public func stopScan() throws -> Bool {
        return onQueueSync {
            if scan != nil, let central = central, central.state == .poweredOn {
                central.stopScan()
            }
            scan = nil
            return true
        }
    }

    public func isScanning() throws -> Bool {
        return onQueueSync { scan != nil }
    }

    // MARK: - Devices

    /**
     * The devices this manager has a link up with, plus those the system holds connected
     * with one of `services` (maybe for another app: connect() makes them usable here).
     * Throws on an invalid service UUID.
     */
    public func getConnectedDevices(services: [String]) throws -> [BLEDevice] {
        let serviceUUIDs = try services.map { serviceId -> CBUUID in
            guard let uuid = CBUUID.parse(serviceId) else {
                throw RuntimeError.error(withMessage: "Invalid service UUID \(serviceId)")
            }
            return uuid
        }
        return onQueueSync {
            guard let central = ensureCentralManager(), central.state == .poweredOn else { return [] }
            var connected: [String: CBPeripheral] = [:]
            for (deviceId, link) in links where link.peripheral.state == .connected {
                connected[deviceId] = link.peripheral
            }
            if !serviceUUIDs.isEmpty {
                for peripheral in central.retrieveConnectedPeripherals(withServices: serviceUUIDs) {
                    connected[peripheral.identifier.uuidString] = peripheral
                }
            }
            return connected.values.map { knownDevice($0) }
        }
    }

    // MARK: - Connection

    /**
     * Requirements (spec "Connection management"):
     * - A connect to a device that already has one pending fails with
     *   DeviceAlreadyConnected; the pending one goes on (as on Android).
     * - On a device that is up (e.g. restored by iOS) it succeeds at once and takes over the
     *   disconnection reports.
     * - ConnectOptions.timeoutMs fails it with OperationTimedOut and cancels the pending
     *   link. autoConnect and refreshGatt are Android options.
     * - disconnectCallback hears about the drop of the link this connect brought up, once.
     */
    public func connect(
        deviceId: String,
        options: ConnectOptions,
        callback: @escaping (BleError?) -> Void,
        disconnectCallback: ((String, Bool, BleError?) -> Void)?
    ) throws {
        let timeoutMs = options.timeoutMs
        onQueueAsync { [self] in
            let fail = { (error: BleError) in callback(error) }
            guard let central = poweredOnCentral(else: fail),
                  let peripheral = findPeripheral(deviceId, in: central, else: fail) else { return }
            let link = self.link(for: peripheral)
            guard link.pendingConnect == nil else {
                return callback(BleError(.devicealreadyconnected, "A connect to \(link.deviceId) is already pending"))
            }
            let goingDown = !link.pendingDisconnects.isEmpty || peripheral.state == .disconnecting
            if peripheral.state == .connected && !goingDown {
                link.disconnectionHandler = disconnectCallback
                return callback(nil)
            }
            let pending = PendingConnect(completion: callback, disconnectionHandler: disconnectCallback)
            link.pendingConnect = pending
            if let timeoutMs = timeoutMs {
                armConnectTimeout(pending, of: link, after: timeoutMs)
            }
            // A link still going down (disconnect requested) is brought up again once
            // didDisconnect reports it down.
            if !goingDown {
                issue(pending, of: link, on: central)
            }
        }
    }

    /// Starts (or restarts) the attempt of `pending`, unless CoreBluetooth already has one going.
    private func issue(_ pending: PendingConnect, of link: BlePeripheralDelegate, on central: CBCentralManager) {
        pending.issued = true
        // A peripheral the system is connecting already (a connection it restored, or the
        // attempt issued before) only needs its didConnect.
        if link.peripheral.state != .connecting {
            central.connect(link.peripheral, options: nil)
        }
    }

    /**
     * Cancels the attempt CoreBluetooth is making for `link` after its caller was answered
     * (timed out, or cancelled by disconnect()). The attempt's own report may still come
     * (see BlePeripheralDelegate.cancelledAttempts).
     */
    private func cancelAttempt(of link: BlePeripheralDelegate, on central: CBCentralManager) {
        link.cancelledAttempts += 1
        central.cancelPeripheralConnection(link.peripheral)
    }

    private func armConnectTimeout(_ pending: PendingConnect, of link: BlePeripheralDelegate, after timeoutMs: Double) {
        let timeout = DispatchWorkItem { [weak self, weak link, weak pending] in
            guard let self = self, let link = link, let pending = pending, link.pendingConnect === pending else { return }
            link.pendingConnect = nil
            if pending.issued, let central = self.central {
                self.cancelAttempt(of: link, on: central)
            }
            pending.completion(BleError(.operationtimedout, "Connect to \(link.deviceId) timed out after \(Int(timeoutMs)) ms"))
        }
        pending.timeout = timeout
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs)), execute: timeout)
    }

    /// Ends the pending connect of `link`, if any: up (`error` nil) or failed.
    private func completeConnect(of link: BlePeripheralDelegate, _ error: BleError?) {
        guard let pending = link.pendingConnect else { return }
        pending.timeout?.cancel()
        link.pendingConnect = nil
        if error == nil {
            link.disconnectionHandler = pending.disconnectionHandler
        }
        pending.completion(error)
    }

    /**
     * Completes once the link is down (didDisconnect). A pending connect fails with
     * OperationCancelled and its attempt is cancelled; the disconnect then completes at once,
     * since CoreBluetooth promises no didDisconnect for a link that never came up (a late one
     * is told apart from the next connect's, see cancelAttempt). Without a link or pending
     * connect it fails with DeviceNotConnected (as ble-plx on Android).
     */
    public func disconnect(deviceId: String, callback: @escaping (BleError?) -> Void) throws {
        onQueueAsync { [self] in
            guard !destroyed else { return callback(Self.destroyedError) }
            guard let id = Self.canonicalDeviceId(deviceId) else { return callback(Self.invalidDeviceId(deviceId)) }
            let notConnected = BleError(.devicenotconnected, "Device \(id) is not connected")
            guard let link = links[id], let central = self.central else { return callback(notConnected) }
            let hadPendingConnect = link.pendingConnect != nil
            completeConnect(of: link, BleError(.operationcancelled, "Connect to \(id) cancelled by disconnect"))
            switch link.peripheral.state {
            case .connected, .disconnecting:
                link.disconnectRequested = true
                link.pendingDisconnects.append(callback)
                if link.peripheral.state == .connected && link.pendingDisconnects.count == 1 {
                    central.cancelPeripheralConnection(link.peripheral)
                }
            case .connecting:
                // Ours, or a connection the system restored.
                cancelAttempt(of: link, on: central)
                callback(nil)
            default:
                callback(hadPendingConnect ? nil : notConnected)
            }
        }
    }

    public func isConnected(deviceId: String) throws -> Bool {
        return onQueueSync { connectedPeripheral(deviceId) != nil }
    }

    /**
     * The link of `link` is down: didDisconnectPeripheral, Bluetooth leaving the powered-on
     * state, or destroy. Every queued request fails with `operationError` (nothing pending
     * outlives its link), the disconnect() calls waiting for it complete, and the handler
     * connect() installed hears about it once: interrupted with `cause`, unless disconnect()
     * or destroy() asked for it (then no error).
     */
    private func linkDown(_ link: BlePeripheralDelegate, operationError: BleError, cause: BleError) {
        let interrupted = !link.disconnectRequested
        let handler = link.disconnectionHandler
        let disconnects = link.pendingDisconnects
        link.disconnectRequested = false
        link.disconnectionHandler = nil
        link.pendingDisconnects = []
        link.linkDown(failingWith: operationError)
        disconnects.forEach { $0(nil) }
        handler?(link.deviceId, interrupted, interrupted ? cause : nil)
    }

    // MARK: - Requests

    /// iOS negotiates the MTU by itself: `mtu` is ignored and the ATT MTU in effect is reported (spec).
    public func requestMTU(deviceId: String, mtu: Double, callback: @escaping (BleError?, Double?) -> Void) throws {
        enqueue(deviceId, GattOperation(.readMTU(callback)))
    }

    /// Android only: completes at once without error (spec).
    public func requestConnectionPriority(
        deviceId: String,
        androidConnectionPriority: AndroidConnectionPriority,
        callback: @escaping (BleError?) -> Void
    ) throws {
        onQueueAsync { callback(nil) }
    }

    public func readRSSI(deviceId: String, callback: @escaping (BleError?, Double?) -> Void) throws {
        enqueue(deviceId, GattOperation(.readRSSI(callback)))
    }

    public func discoverServices(deviceId: String, callback: @escaping (BleError?) -> Void) throws {
        enqueue(deviceId, GattOperation(.discover(withCharacteristics: false, callback)))
    }

    public func discoverServicesWithCharacteristics(deviceId: String, callback: @escaping (BleError?) -> Void) throws {
        enqueue(deviceId, GattOperation(.discover(withCharacteristics: true, callback)))
    }

    /// Full lowercase 128-bit UUIDs; empty when not connected or not discovered.
    public func getServices(deviceId: String) throws -> [String] {
        return onQueueSync {
            connectedPeripheral(deviceId)?.services?.map { $0.uuid.fullUUIDString } ?? []
        }
    }

    /// Full lowercase 128-bit UUIDs; empty when not connected or not discovered. Throws on an invalid UUID.
    public func getCharacteristics(deviceId: String, serviceId: String) throws -> [String] {
        guard let serviceUUID = CBUUID.parse(serviceId) else {
            throw RuntimeError.error(withMessage: "Invalid service UUID \(serviceId)")
        }
        return onQueueSync {
            let service = connectedPeripheral(deviceId)?.services?.first { $0.uuid == serviceUUID }
            return service?.characteristics?.map { $0.uuid.fullUUIDString } ?? []
        }
    }

    public func readCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: @escaping (BleError?, ArrayBuffer?) -> Void
    ) throws {
        guard let key = characteristicKey(serviceId, characteristicId, else: { callback($0, nil) }) else { return }
        enqueue(deviceId, GattOperation(.read(key, callback)))
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
        guard let key = characteristicKey(serviceId, characteristicId, else: { callback($0, nil) }) else { return }
        let bytes = Data(bytes: data.data, count: data.size)
        enqueue(deviceId, GattOperation(.write(key, bytes, withResponse: withResponse, callback)))
    }

    /**
     * Completes on didUpdateNotificationStateFor. Each notification's bytes are copied once
     * into a buffer of their own and handed to `updateCallback` on the queue.
     */
    public func subscribeToCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        updateCallback: @escaping (ArrayBuffer) -> Void,
        completionCallback: @escaping (BleError?) -> Void
    ) throws {
        guard let key = characteristicKey(serviceId, characteristicId, else: { completionCallback($0) }) else { return }
        enqueue(deviceId, GattOperation(.setNotify(key, updateCallback, completionCallback)))
    }

    public func unsubscribeFromCharacteristic(
        deviceId: String,
        serviceId: String,
        characteristicId: String,
        callback: @escaping (BleError?) -> Void
    ) throws {
        guard let key = characteristicKey(serviceId, characteristicId, else: { callback($0) }) else { return }
        enqueue(deviceId, GattOperation(.setNotify(key, nil, callback)))
    }

    /// Whether the characteristic notifies (its CCCD write succeeded). Throws on an invalid UUID.
    public func isSubscribedToCharacteristic(deviceId: String, serviceId: String, characteristicId: String) throws -> Bool {
        guard let serviceUUID = CBUUID.parse(serviceId), let characteristicUUID = CBUUID.parse(characteristicId) else {
            throw RuntimeError.error(withMessage: "Invalid service or characteristic UUID \(serviceId) / \(characteristicId)")
        }
        return onQueueSync {
            let service = connectedPeripheral(deviceId)?.services?.first { $0.uuid == serviceUUID }
            return service?.characteristics?.first { $0.uuid == characteristicUUID }?.isNotifying ?? false
        }
    }

    /// Queues `operation` on its device's link, behind everything requested before it.
    private func enqueue(_ deviceId: String, _ operation: GattOperation) {
        onQueueAsync { [self] in
            guard !destroyed else { return operation.fail(Self.destroyedError) }
            linkForRequest(deviceId, else: operation.fail)?.enqueue(operation)
        }
    }

    /// Parses a request's UUIDs; an invalid one fails the request with InvalidIdentifiers (from the queue, like every callback).
    private func characteristicKey(
        _ serviceId: String,
        _ characteristicId: String,
        else fail: @escaping (BleError) -> Void
    ) -> CharacteristicKey? {
        guard let service = CBUUID.parse(serviceId), let characteristic = CBUUID.parse(characteristicId) else {
            let error = BleError(.invalididentifiers, "Invalid service or characteristic UUID \(serviceId) / \(characteristicId)")
            onQueueAsync { fail(error) }
            return nil
        }
        return CharacteristicKey(service: service, characteristic: characteristic)
    }

    // MARK: - Lookup

    /// Device ids are CBPeripheral.identifier.uuidString; a caller's spelling is normalized through UUID.
    private static func canonicalDeviceId(_ deviceId: String) -> String? {
        return UUID(uuidString: deviceId)?.uuidString
    }

    private static func invalidDeviceId(_ deviceId: String) -> BleError {
        return BleError(.invalididentifiers, "Invalid device id \(deviceId)")
    }

    /// The one delegate of `peripheral`, created on first use.
    private func link(for peripheral: CBPeripheral) -> BlePeripheralDelegate {
        let deviceId = peripheral.identifier.uuidString
        if let link = links[deviceId] {
            return link
        }
        let link = BlePeripheralDelegate(peripheral: peripheral, queue: queue)
        links[deviceId] = link
        return link
    }

    /**
     * The peripheral `deviceId` names: one this manager holds, else one the system knows.
     * Calls `fail` and returns nil when the id is invalid or unknown.
     */
    private func findPeripheral(_ deviceId: String, in central: CBCentralManager, else fail: (BleError) -> Void) -> CBPeripheral? {
        guard let uuid = UUID(uuidString: deviceId) else {
            fail(Self.invalidDeviceId(deviceId))
            return nil
        }
        let id = uuid.uuidString
        guard let peripheral = links[id]?.peripheral ?? discovered[id] ?? central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            fail(BleError(.devicenotfound, "Device \(id) not found"))
            return nil
        }
        return peripheral
    }

    /**
     * The link a request on `deviceId` is queued on. A peripheral that is up without a
     * connect() from this manager (the system connected it) gets its delegate here, on its
     * first request. Calls `fail` and returns nil when the id is invalid or the device is
     * not connected.
     */
    private func linkForRequest(_ deviceId: String, else fail: (BleError) -> Void) -> BlePeripheralDelegate? {
        guard let uuid = UUID(uuidString: deviceId) else {
            fail(Self.invalidDeviceId(deviceId))
            return nil
        }
        if let link = links[uuid.uuidString] {
            return link
        }
        if let central = central, central.state == .poweredOn,
           let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first,
           peripheral.state == .connected {
            return link(for: peripheral)
        }
        fail(BleError(.devicenotconnected, "Device \(uuid.uuidString) is not connected"))
        return nil
    }

    private func connectedPeripheral(_ deviceId: String) -> CBPeripheral? {
        guard let id = Self.canonicalDeviceId(deviceId), let peripheral = links[id]?.peripheral,
              peripheral.state == .connected else { return nil }
        return peripheral
    }

    // MARK: - Destroy

    /**
     * Stops the scan (its callback hears nothing more), fails every pending connect, request
     * and disconnect() with BluetoothManagerDestroyed, closes every link (a link that was up
     * reports its drop as requested: interrupted false, no error), then releases the central.
     * Afterwards callback methods fail with BluetoothManagerDestroyed and getters report
     * nothing connected, no scan and state Unknown.
     */
    public func destroy() throws {
        onQueueSync {
            guard !destroyed else { return }
            destroyed = true
            let liveCentral = central?.state == .poweredOn ? central : nil
            if scan != nil {
                liveCentral?.stopScan()
            }
            scan = nil
            for link in links.values {
                completeConnect(of: link, Self.destroyedError)
                let disconnects = link.pendingDisconnects
                link.pendingDisconnects = []
                disconnects.forEach { $0(Self.destroyedError) }
                if link.peripheral.state != .disconnected {
                    liveCentral?.cancelPeripheralConnection(link.peripheral)
                }
                link.disconnectRequested = true
                linkDown(link, operationError: Self.destroyedError, cause: Self.destroyedError)
            }
            forgetPeripherals()
            central?.delegate = nil
            central = nil
            centralDelegate = nil
            stateCallback = nil
            restoreCallback = nil
        }
    }

    // MARK: - CBCentralManagerDelegate (on the queue)

    fileprivate func centralDidUpdateState(_ central: CBCentralManager) {
        if let unavailable = central.state.unavailableError {
            bluetoothBecameUnavailable(central.state, unavailable)
        }
        // CoreBluetooth calls willRestoreState before the first state update when it restores
        // anything (Apple: the first method invoked on a restoration launch). Getting here
        // with nothing reported means there was nothing to restore: the callback gets an empty
        // list, once, as ble-plx emits a null restored state on a first run
        // (BleModule.onRestoreState).
        if restoresState {
            reportRestoredState([])
        }
        stateCallback?(central.state.bleState)
    }

    /**
     * Bluetooth left the powered-on state, which ends every link and the scan without a
     * didDisconnectPeripheral for each. As in ble-plx (RxBluetoothKit fails whatever needs a
     * powered-on central with the state's error), the scan and pending connects fail with
     * the state's error; links that were up drop like any other (DeviceDisconnected). A
     * didDisconnectPeripheral arriving after this finds nothing left to report.
     *
     * At poweredOff the peripheral objects stay valid, so their delegates (and restored
     * peripherals) are kept. Below it (resetting, unauthorized, unsupported, unknown),
     * CoreBluetooth invalidates every CBPeripheral the central handed out; they "must be
     * retrieved or discovered again" (CBCentralManager.h, centralManagerDidUpdateState:).
     * They are forgotten then, so the next connect or request retrieves a valid one instead
     * of waiting forever on a dead object.
     */
    private func bluetoothBecameUnavailable(_ state: CBManagerState, _ unavailable: BleError) {
        if let scan = scan {
            self.scan = nil
            scan.callback?(nil, unavailable)
        }
        for link in links.values {
            completeConnect(of: link, unavailable)
            // CoreBluetooth ended every attempt with the radio: no late report is owed.
            link.cancelledAttempts = 0
            let dropped = BleError(.devicedisconnected, "Device \(link.deviceId) disconnected: \(unavailable.message)")
            linkDown(link, operationError: dropped, cause: dropped)
        }
        if state.rawValue < CBManagerState.poweredOff.rawValue {
            forgetPeripherals()
        }
    }

    /// Releases every peripheral this manager holds: their delegates and the scan results.
    private func forgetPeripherals() {
        links.values.forEach { $0.peripheral.delegate = nil }
        links.removeAll()
        discovered.removeAll()
    }

    /**
     * Restored peripherals get their delegate now; a link that is up reports its drop once
     * connect() installed a handler (connect on a connected device succeeds at once).
     */
    fileprivate func centralWillRestoreState(_ state: [String: Any]) {
        let peripherals = state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let devices = peripherals.map { peripheral -> BLEDevice in
            _ = link(for: peripheral)
            return knownDevice(peripheral)
        }
        if state[CBCentralManagerRestoredStateScanServicesKey] != nil {
            scan = Scan(callback: nil, rssiThreshold: nil)
        }
        reportRestoredState(devices)
    }

    fileprivate func centralDidDiscover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard let scan = scan, let callback = scan.callback else { return }
        if let threshold = scan.rssiThreshold, rssi.doubleValue < threshold {
            return
        }
        discovered[peripheral.identifier.uuidString] = peripheral
        callback(advertisedDevice(peripheral, advertisementData, rssi: rssi.doubleValue), nil)
    }

    fileprivate func centralDidConnect(_ peripheral: CBPeripheral) {
        guard let link = links[peripheral.identifier.uuidString] else { return }
        link.cancelledAttempts = 0
        completeConnect(of: link, nil)
    }

    fileprivate func centralDidFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        guard let link = links[peripheral.identifier.uuidString] else { return }
        if link.cancelledAttempts > 0 {
            // The late report of a cancelled attempt: the connect pending now goes on, issued
            // again in case CoreBluetooth ended its attempt along with the cancelled one.
            link.cancelledAttempts -= 1
            if let pending = link.pendingConnect, let central = central {
                issue(pending, of: link, on: central)
            }
            return
        }
        guard link.pendingConnect != nil else { return }
        let failure = BleError(.deviceconnectionfailed, "Connect to \(link.deviceId) failed", cause: error)
        link.linkDown(failingWith: failure)
        completeConnect(of: link, failure)
    }

    fileprivate func centralDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard let link = links[peripheral.identifier.uuidString] else { return }
        if link.cancelledAttempts > 0 {
            // The late report of a cancelled attempt, not of the connect pending now: that one
            // goes on below.
            link.cancelledAttempts -= 1
        } else if let pending = link.pendingConnect, pending.issued {
            // Down before it came up.
            completeConnect(of: link, BleError(.deviceconnectionfailed, "Connect to \(link.deviceId) failed", cause: error))
        }
        let dropped = BleError(.devicedisconnected, "Device \(link.deviceId) disconnected", cause: error)
        linkDown(link, operationError: dropped, cause: dropped)
        // A connect still pending starts now: one requested while the link was going down, or
        // one whose attempt CoreBluetooth may have ended along with a cancelled one.
        if let pending = link.pendingConnect, let central = central {
            issue(pending, of: link, on: central)
        }
    }

    // MARK: - Devices

    private func advertisedDevice(_ peripheral: CBPeripheral, _ advertisementData: [String: Any], rssi: Double) -> BLEDevice {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return BLEDevice(
            id: peripheral.identifier.uuidString,
            // "" when the device has no name, as on Android.
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "",
            rssi: rssi,
            manufacturerData: manufacturerData(advertisementData),
            serviceData: serviceData(advertisementData),
            serviceUUIDs: serviceUUIDs.map { $0.fullUUIDString },
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? true,
            isConnected: peripheral.state == .connected
        )
    }

    /**
     * A device known without an advertisement (restored, or connected): no RSSI (see
     * rssiUnavailable), advertisement data or advertised connectability. isConnectable is
     * true since it was connected to; isConnected tells whether this app's link is up.
     */
    private func knownDevice(_ peripheral: CBPeripheral) -> BLEDevice {
        return BLEDevice(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            rssi: Self.rssiUnavailable,
            manufacturerData: ManufacturerData(companyIdentifiers: []),
            serviceData: ServiceData(services: []),
            serviceUUIDs: peripheral.services?.map { $0.uuid.fullUUIDString } ?? [],
            isConnectable: true,
            isConnected: peripheral.state == .connected
        )
    }

    /// One entry: `id` the company identifier (little endian, as a decimal string), `data` the bytes after it.
    private func manufacturerData(_ advertisementData: [String: Any]) -> ManufacturerData {
        guard let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, raw.count >= 2 else {
            return ManufacturerData(companyIdentifiers: [])
        }
        let companyId = UInt16(raw[raw.startIndex]) | UInt16(raw[raw.startIndex + 1]) << 8
        let entry = ManufacturerDataEntry(id: String(companyId), data: ArrayBuffer.copying(raw.dropFirst(2)))
        return ManufacturerData(companyIdentifiers: [entry])
    }

    private func serviceData(_ advertisementData: [String: Any]) -> ServiceData {
        let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return ServiceData(services: raw.map { ServiceDataEntry(uuid: $0.key.fullUUIDString, data: ArrayBuffer.copying($0.value)) })
    }
}

/// Forwards the central's delegate calls, which arrive on the manager's queue. A separate
/// NSObject since the HybridObject base class is none.
final class BleCentralManagerDelegate: NSObject, CBCentralManagerDelegate {
    private weak var manager: BleNitroBleManager?

    init(manager: BleNitroBleManager) {
        self.manager = manager
        super.init()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        manager?.centralDidUpdateState(central)
    }

    /// Always handled when a restore identifier is set (CoreBluetooth only calls it then).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        manager?.centralWillRestoreState(dict)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        manager?.centralDidDiscover(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        manager?.centralDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        manager?.centralDidFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        manager?.centralDidDisconnect(peripheral, error: error)
    }
}
