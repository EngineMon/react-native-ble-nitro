import Foundation
import CoreBluetooth
import NitroModules

typealias BleCompletion = (BleError?) -> Void
typealias BleValueCompletion = (BleError?, ArrayBuffer?) -> Void
typealias BleNumberCompletion = (BleError?, Double?) -> Void
typealias BleNotificationHandler = (ArrayBuffer) -> Void
typealias BleDisconnectionHandler = (String, Bool, BleError?) -> Void

/**
 * A characteristic as callers name it: service UUID + characteristic UUID. Requests and
 * subscriptions are keyed by it, not by CBCharacteristic objects (CoreBluetooth makes new
 * ones when it rediscovers services) and not by the characteristic UUID alone (two
 * services may have characteristics with the same UUID).
 */
struct CharacteristicKey: Hashable, CustomStringConvertible {
    let service: CBUUID
    let characteristic: CBUUID

    var description: String {
        return "characteristic \(characteristic.fullUUIDString) of service \(service.fullUUIDString)"
    }
}

/// A connect waiting for its link to come up.
final class PendingConnect {
    let completion: BleCompletion
    /// Installed on the link once it is up: only a link that came up reports its drop.
    let disconnectionHandler: BleDisconnectionHandler?
    /// Fires after ConnectOptions.timeoutMs.
    var timeout: DispatchWorkItem?
    /// False while the connect waits for the device's previous link to finish going down.
    var issued = false

    init(completion: @escaping BleCompletion, disconnectionHandler: BleDisconnectionHandler?) {
        self.completion = completion
        self.disconnectionHandler = disconnectionHandler
    }
}

/// One request queued on a peripheral.
final class GattOperation {
    enum Kind {
        case read(CharacteristicKey, BleValueCompletion)
        /// `Data` is the operation's own copy of the bytes, taken when the request was made.
        case write(CharacteristicKey, Data, withResponse: Bool, BleValueCompletion)
        /// A handler subscribes, nil unsubscribes.
        case setNotify(CharacteristicKey, BleNotificationHandler?, BleCompletion)
        case readRSSI(BleNumberCompletion)
        case discover(withCharacteristics: Bool, BleCompletion)
        case readMTU(BleNumberCompletion)
    }

    let kind: Kind
    /// The characteristic the operation resolved when it started.
    var characteristic: CBCharacteristic?
    /// Discovery with characteristics: the services whose characteristics are still coming.
    var servicesInDiscovery: [CBService] = []

    init(_ kind: Kind) {
        self.kind = kind
    }

    func fail(_ error: BleError) {
        switch kind {
        case .read(_, let completion), .write(_, _, _, let completion):
            completion(error, nil)
        case .setNotify(_, _, let completion), .discover(_, let completion):
            completion(error)
        case .readRSSI(let completion), .readMTU(let completion):
            completion(error, nil)
        }
    }

    /// What the operation does, for error messages.
    var summary: String {
        switch kind {
        case .read(let key, _):
            return "Read of \(key)"
        case .write(let key, _, let withResponse, _):
            return withResponse ? "Write to \(key)" : "Write without response to \(key)"
        case .setNotify(let key, let handler, _):
            return handler == nil ? "Unsubscribe from \(key)" : "Subscribe to \(key)"
        case .readRSSI:
            return "RSSI read"
        case .discover(let withCharacteristics, _):
            return withCharacteristics ? "Discovery of services and characteristics" : "Service discovery"
        case .readMTU:
            return "MTU request"
        }
    }
}

/**
 * The CBPeripheralDelegate of one peripheral, and everything pending on it. A peripheral
 * has exactly one (the manager keeps it in `links`). Runs on the manager's queue only.
 *
 * Requests run one at a time, in call order (spec: operations on one device run one at a
 * time): each waits in `operations` until the one before it completed, failed or timed
 * out. When the link goes down every queued request fails (`linkDown`), so none waits
 * for an answer that can't come.
 *
 * Connection state (`pendingConnect`, `disconnectionHandler`, `pendingDisconnects`,
 * `disconnectRequested`, `cancelledAttempts`) lives here too, but the manager drives it
 * from the central's delegate calls.
 */
final class BlePeripheralDelegate: NSObject, CBPeripheralDelegate {
    /**
     * How long one request may take before it fails with OperationTimedOut: RxAndroidBle's
     * default operation timeout, also used on Android. CoreBluetooth may still answer a
     * timed-out request later; that answer is matched like any other (by kind and
     * characteristic), so it can complete a later request of the same kind on the same
     * characteristic early.
     */
    private static let operationTimeoutSeconds = 30
    /// ATT MTU = longest write without response + the ATT header (opcode and handle).
    private static let attHeaderSize = 3

    let peripheral: CBPeripheral
    let deviceId: String

    var pendingConnect: PendingConnect?
    /// connect()'s handler, while the link it brought up is up.
    var disconnectionHandler: BleDisconnectionHandler?
    /// disconnect() calls waiting for the link to go down.
    var pendingDisconnects: [BleCompletion] = []
    /// disconnect() or destroy() asked for the link to go down: its drop is not interrupted.
    var disconnectRequested = false
    /**
     * Connect attempts cancelled after their caller was answered (connect timed out, or
     * disconnect() while connecting), for which CoreBluetooth may still report
     * didDisconnectPeripheral or didFailToConnect. That report can arrive after connect() was
     * called again; it belongs to the old attempt and must not fail the new one, so the
     * manager counts it off here first. Reset when a link comes up (CoreBluetooth reports a
     * peripheral's events in order, so nothing from an earlier attempt can still come) and
     * when Bluetooth goes off; that also bounds the count if CoreBluetooth never reports a
     * cancelled attempt.
     */
    var cancelledAttempts = 0

    private var operations: [GattOperation] = []
    private var current: GattOperation?
    private var isStartingOperations = false
    /**
     * One timer per peripheral, re-armed for each request when it starts, instead of a work
     * item per request: during a burst of writes, finished requests leave nothing behind
     * on the queue. A firing that was already on its way when its request finished sees a
     * later deadline and does nothing.
     */
    private let operationTimer: DispatchSourceTimer
    private var operationDeadline = DispatchTime.distantFuture
    private var subscriptions: [CharacteristicKey: BleNotificationHandler] = [:]

    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.deviceId = peripheral.identifier.uuidString
        self.operationTimer = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        operationTimer.setEventHandler { [weak self] in
            self?.operationTimerFired()
        }
        operationTimer.resume()
        peripheral.delegate = self
    }

    deinit {
        operationTimer.cancel()
    }

    // MARK: - Request queue

    func enqueue(_ operation: GattOperation) {
        operations.append(operation)
        startOperations()
    }

    /**
     * The link is down, or the manager is going away: every queued request fails with
     * `error`, and the subscriptions end (CoreBluetooth ends them with the link; a new link
     * subscribes again).
     */
    func linkDown(failingWith error: BleError) {
        let failed = (current.map { [$0] } ?? []) + operations
        current = nil
        operations.removeAll()
        subscriptions.removeAll()
        failed.forEach { $0.fail(error) }
    }

    private func startOperations() {
        // A request that completes inside start() (a write without response the OS has room
        // for, the MTU, a missing characteristic) comes back here through finish(). The loop
        // goes on instead of recursing, so a long queue of them doesn't grow the stack.
        guard !isStartingOperations else { return }
        isStartingOperations = true
        defer { isStartingOperations = false }
        while current == nil, !operations.isEmpty {
            let operation = operations.removeFirst()
            current = operation
            operationDeadline = .now() + .seconds(Self.operationTimeoutSeconds)
            operationTimer.schedule(deadline: operationDeadline)
            start(operation)
        }
    }

    /// Completes the request in flight through `deliver`, then starts the next one.
    private func finish(_ operation: GattOperation, _ deliver: () -> Void) {
        guard current === operation else { return }
        current = nil
        deliver()
        startOperations()
    }

    private func operationTimerFired() {
        guard let operation = current, DispatchTime.now() >= operationDeadline else { return }
        finish(operation) {
            operation.fail(BleError(.operationtimedout, "\(operation.summary) on \(deviceId) timed out after \(Self.operationTimeoutSeconds) s"))
        }
    }

    private func start(_ operation: GattOperation) {
        guard peripheral.state == .connected else {
            finish(operation) {
                operation.fail(BleError(.devicenotconnected, "Device \(deviceId) is not connected"))
            }
            return
        }
        switch operation.kind {
        case .read(let key, _):
            guard let characteristic = resolve(key, for: operation) else { return }
            peripheral.readValue(for: characteristic)
        case .write(let key, let data, let withResponse, _):
            guard let characteristic = resolve(key, for: operation) else { return }
            if withResponse {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            } else {
                writeWithoutResponseIfReady(operation)
            }
        case .setNotify(let key, let handler, let completion):
            guard let characteristic = resolve(key, for: operation) else { return }
            setNotify(operation, characteristic, key, handler, completion)
        case .readRSSI:
            peripheral.readRSSI()
        case .discover:
            peripheral.discoverServices(nil)
        case .readMTU(let completion):
            // iOS negotiates the MTU by itself; the request reports the one in effect.
            let mtu = Double(peripheral.maximumWriteValueLength(for: .withoutResponse) + Self.attHeaderSize)
            finish(operation) { completion(nil, mtu) }
        }
    }

    /**
     * The characteristic `key` names, looked up when the request starts, so a request
     * queued behind a discovery sees its result. Fails the request and returns nil when
     * there is none.
     */
    private func resolve(_ key: CharacteristicKey, for operation: GattOperation) -> CBCharacteristic? {
        guard let service = peripheral.services?.first(where: { $0.uuid == key.service }) else {
            finish(operation) {
                operation.fail(BleError(.servicenotfound, "Service \(key.service.fullUUIDString) not found on \(deviceId)"))
            }
            return nil
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == key.characteristic }) else {
            finish(operation) {
                operation.fail(BleError(.characteristicnotfound, "No \(key) on \(deviceId)"))
            }
            return nil
        }
        operation.characteristic = characteristic
        return characteristic
    }

    /**
     * A write without response completes once the OS took it (spec), so awaiting each
     * write paces a burst. CoreBluetooth has room for a limited number of them; like
     * RxBluetoothKit's Peripheral.writeValue (ble-plx), this writes as soon as
     * canSendWriteWithoutResponse is true, else when peripheralIsReady says it became so.
     */
    private func writeWithoutResponseIfReady(_ operation: GattOperation) {
        guard peripheral.canSendWriteWithoutResponse,
              case .write(_, let data, _, let completion) = operation.kind,
              let characteristic = operation.characteristic else { return }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        finish(operation) { completion(nil, Self.writtenBytes(data)) }
    }

    /**
     * What a successful write reports: the bytes written, as on Android (CoreBluetooth has
     * no write response payload). A copy of its own: CoreBluetooth may still hold the
     * written Data, and the caller may change the buffer it gets.
     */
    private static func writtenBytes(_ data: Data) -> ArrayBuffer {
        return ArrayBuffer.copying(data)
    }

    private func setNotify(
        _ operation: GattOperation,
        _ characteristic: CBCharacteristic,
        _ key: CharacteristicKey,
        _ handler: BleNotificationHandler?,
        _ completion: BleCompletion
    ) {
        let enable = handler != nil
        if enable && !characteristic.properties.contains(.notify) && !characteristic.properties.contains(.indicate) {
            finish(operation) {
                completion(BleError(.characteristicnotifychangefailed, "\(key) on \(deviceId) supports neither notify nor indicate"))
            }
            return
        }
        // Delivery follows call order: an unsubscribe stops it now, a subscribe starts it
        // before the CCCD write so no notification right after it is lost. Subscribing again
        // replaces the handler (spec).
        subscriptions[key] = handler
        // Nothing to write when the notify state already is the one asked for (e.g. a
        // peripheral restored with notifications on).
        if characteristic.isNotifying == enable {
            finish(operation) { completion(nil) }
            return
        }
        peripheral.setNotifyValue(enable, for: characteristic)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let operation = current, case .discover(let withCharacteristics, let completion) = operation.kind else { return }
        if let error = error {
            finish(operation) {
                completion(BleError(.servicesdiscoveryfailed, "Service discovery on \(deviceId) failed", cause: error))
            }
            return
        }
        // Only services without characteristics are asked: CoreBluetooth may skip
        // didDiscoverCharacteristicsFor for a service whose characteristics it has cached,
        // which would leave the request waiting.
        let pending = withCharacteristics ? (peripheral.services ?? []).filter({ $0.characteristics == nil }) : []
        guard !pending.isEmpty else {
            finish(operation) { completion(nil) }
            return
        }
        operation.servicesInDiscovery = pending
        pending.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let operation = current, case .discover(_, let completion) = operation.kind,
              let index = operation.servicesInDiscovery.firstIndex(where: { $0 === service }) else { return }
        if let error = error {
            finish(operation) {
                completion(BleError(.characteristicsdiscoveryfailed, "Characteristic discovery of service \(service.uuid.fullUUIDString) on \(deviceId) failed", cause: error))
            }
            return
        }
        operation.servicesInDiscovery.remove(at: index)
        if operation.servicesInDiscovery.isEmpty {
            finish(operation) { completion(nil) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let operation = current, case .discover(_, let completion) = operation.kind else { return }
        finish(operation) {
            completion(BleError(.servicesdiscoveryfailed, "Services of \(deviceId) changed during discovery"))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // A read's answer arrives here just like a notification. A read waiting for this
        // characteristic is served first; the subscription then gets the value too.
        if let operation = current, operation.characteristic === characteristic, case .read(let key, let completion) = operation.kind {
            if error == nil, let value = characteristic.value {
                finish(operation) { completion(nil, ArrayBuffer.copying(value)) }
            } else {
                finish(operation) {
                    completion(BleError(.characteristicreadfailed, "Read of \(key) on \(deviceId) failed", cause: error), nil)
                }
            }
        }
        // The notification hot path: one lookup and one copy, then the handler, which for a
        // C++ consumer runs right here on the queue. An update with an error has no value to
        // deliver, and NotificationCallback has no error to carry.
        guard error == nil,
              let service = characteristic.service,
              let value = characteristic.value,
              let handler = subscriptions[CharacteristicKey(service: service.uuid, characteristic: characteristic.uuid)] else { return }
        handler(ArrayBuffer.copying(value))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let operation = current, operation.characteristic === characteristic,
              case .write(let key, let data, withResponse: true, let completion) = operation.kind else { return }
        if let error = error {
            finish(operation) {
                completion(BleError(.characteristicwritefailed, "Write to \(key) on \(deviceId) failed", cause: error), nil)
            }
        } else {
            finish(operation) { completion(nil, Self.writtenBytes(data)) }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let operation = current, case .write(_, _, withResponse: false, _) = operation.kind else { return }
        writeWithoutResponseIfReady(operation)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let operation = current, operation.characteristic === characteristic,
              case .setNotify(let key, let handler, let completion) = operation.kind else { return }
        let enable = handler != nil
        if error == nil && characteristic.isNotifying == enable {
            finish(operation) { completion(nil) }
            return
        }
        if enable {
            subscriptions[key] = nil
        }
        finish(operation) {
            completion(BleError(.characteristicnotifychangefailed, "\(operation.summary) on \(deviceId) failed", cause: error))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let operation = current, case .readRSSI(let completion) = operation.kind else { return }
        if let error = error {
            finish(operation) {
                completion(BleError(.devicerssireadfailed, "RSSI read on \(deviceId) failed", cause: error), nil)
            }
        } else {
            finish(operation) { completion(nil, RSSI.doubleValue) }
        }
    }
}
