import Foundation
import CoreBluetooth
import NitroModules

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

/// The outcome of looking a characteristic up for a request (`GattSession.resolve`/`find`).
enum CharacteristicLookup {
    case found(CBCharacteristic)
    case failed(BleError)
}

/**
 * The GATT state of one link of this manager: its operation queue, its subscriptions with
 * their CCCD state, and which services the device invalidated. A PeripheralLink creates
 * one when the link comes up and drops it when the link goes down, so nothing of a
 * previous link (a queued request, a subscription, a tracked CCCD state, an invalidated
 * service, a stalled queue) survives into the next. Runs on the manager's queue only.
 *
 * Requests run one at a time in call order (GattOperationQueue; one class per request in
 * GattSessionOperations.swift). Characteristic requests look the characteristic up when
 * they start, so one queued behind discoverServices sees its result, and check in the
 * order NativeBleNitro.nitro.ts lists the lookup errors (`resolve`):
 * - ServicesNotDiscovered (303): no services discovered (`peripheral.services` nil), or
 *   the device changed the service since the last discovery (see `servicesModified`);
 * - ServiceNotFound (302); CharacteristicsNotDiscovered (405): the service's
 *   characteristics aren't discovered; CharacteristicNotFound (404);
 * - the declared properties and the write length (GattRules.violation): read 402,
 *   writes 401, subscribe 403, without nativeStatus.
 *
 * Every operation timeout stalls the queue and takes the link down (`onStall`). The
 * database generation is the hub's (`NotificationHub.generation`): both move together,
 * since a change of the database is what ends subscriptions without their owners.
 */
final class GattSession {
    typealias Subscriptions = NotificationHub<CharacteristicKey, Data, BleError>

    let peripheral: CBPeripheral
    let deviceId: String

    private let timer: DispatchOperationTimer
    /// The link's stall hook (see `init`).
    private let onStall: (BleError) -> Void
    /// The manager's destroy() was called (see `isManagerDestroying`).
    private let managerDestroying: () -> Bool
    /// Lazy only so that `onStall` can capture `self` weakly: a closure can't capture
    /// `self` before every stored property is initialized.
    private lazy var operations = GattOperationQueue<SessionOperation>(
        timer: self.timer,
        timeoutError: operationTimedOutError,
        onStall: { [weak self] operation in self?.operationTimedOut(operation) }
    )
    /**
     * Values are the `Data` CoreBluetooth hands over, not buffers: a value is copied into
     * an ArrayBuffer only by a subscriber's listener (the facade wraps each), so a value
     * nobody listens to costs no copy, and every subscriber gets a buffer of its own that
     * no other subscriber can change.
     */
    private let subscriptions = Subscriptions(cancelledError: cancelledError)
    /**
     * Services the device changed since the last discovery (didModifyServices). Requests on
     * them fail with ServicesNotDiscovered until discoverServices succeeds again
     * (NativeBleNitro.nitro.ts, ConnectionEventType.ServicesChanged), rather than with
     * ServiceNotFound because CoreBluetooth dropped them from `peripheral.services`.
     */
    private var invalidatedServices: Set<CBUUID> = []

    /**
     * - Parameters:
     *   - queue: the manager's queue; the operation timeouts run on it.
     *   - isManagerDestroying: whether the manager's destroy() was called (LinkOwner.isDestroying).
     *   - onStall: called with the stall error (OperationTimedOut, naming the operation)
     *     when an operation timed out, before that operation's failure fires. The link
     *     marks itself closing, cancels its connection and closes this session, which
     *     fails the timed-out operation first. Must not capture the link strongly (the
     *     link holds the session).
     */
    init(
        peripheral: CBPeripheral,
        deviceId: String,
        queue: DispatchQueue,
        isManagerDestroying: @escaping () -> Bool,
        onStall: @escaping (BleError) -> Void
    ) {
        self.peripheral = peripheral
        self.deviceId = deviceId
        self.timer = DispatchOperationTimer(queue: queue)
        self.managerDestroying = isManagerDestroying
        self.onStall = onStall
    }

    /**
     * The ATT MTU in effect: `maximumWriteValueLength(for: .withoutResponse)` + 3.
     *
     * Empirical, not documented by Apple. iOS negotiates the MTU by itself and has no API
     * for it; `maximumWriteValueLength(for:)` is documented only as the most one write of
     * that type can carry. For a write without response that is what one ATT Write
     * Command carries, ATT_MTU minus its 3-octet header (opcode and handle, Bluetooth Core
     * Specification Vol 3 Part F §3.4.5.3), so adding the header back gives the MTU as
     * long as iOS keeps that relation. The longest write without response is then
     * min(attMtu − 3, 512), what `resolve` enforces. Read when the request runs:
     * CoreBluetooth exchanges the MTU shortly after connecting, so an early value may still
     * be the default 23.
     */
    var attMtu: Int {
        return peripheral.maximumWriteValueLength(for: .withoutResponse) + GattRules.attWriteHeader
    }

    // MARK: - Requests (from the manager, for a link that is up)

    func read(_ key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) {
        operations.enqueue(ReadOperation(self, key: key, reply: reply))
    }

    /// `data` is the caller's bytes, copied on the caller's thread. Completes with the bytes written, as on Android.
    func write(_ key: CharacteristicKey, data: Data, withResponse: Bool, reply: Reply<ArrayBuffer, BleError>) {
        operations.enqueue(WriteOperation(self, key: key, data: data, withResponse: withResponse, reply: reply))
    }

    /**
     * Adds subscriber `id` of `key` and queues its CCCD operation. The subscriber gets
     * values from now on, before its completion (a device may notify as soon as its CCCD
     * is on).
     *
     * Requirement: a subscriber is added only to a session whose queue is open. On a closed
     * one its CCCD operation would fail with `.queueClosed`, which leaves it Pending for
     * an end of the subscriptions that already ran, so its completion would never fire.
     * The manager hands requests only to a link that is up, whose queue is open; should a
     * closed one get here anyway, the subscribe fails at once with DeviceNotConnected and
     * is never added.
     */
    func subscribe(id: Int64, key: CharacteristicKey, onValue: Listener<Data>, completion: Reply<Void, BleError>, onEnded: Once<BleError>?) {
        guard !operations.isClosed else {
            bleLogWithCallStack("Subscription \(id) was made on a closed session of \(deviceId)")
            completion.fail(notConnectedError(deviceId))
            return
        }
        subscriptions.add(id: id, key: key, onValue: onValue, completion: completion, onEnded: onEnded)
        operations.enqueue(CccdOperation.subscribe(self, id: id, key: key))
    }

    /**
     * Ends subscription `id` if it belongs to this link: delivery to it stops at once (a
     * Pending one's completion fails with OperationCancelled), and a CCCD operation is
     * queued that writes the descriptor off if it was the characteristic's last
     * subscriber. Returns false, without touching `reply`, when this link has no
     * subscription `id` (never made here, already ended or unsubscribed).
     */
    func unsubscribe(id: Int64, reply: Reply<Void, BleError>) -> Bool {
        guard let key = subscriptions.remove(id: id) else { return false }
        operations.enqueue(CccdOperation.unsubscribe(self, key: key, reply: reply))
        return true
    }

    func readRSSI(reply: Reply<Double, BleError>) {
        operations.enqueue(RssiOperation(self, reply: reply))
    }

    /// See MtuOperation: completes with `attMtu` when its turn comes.
    func requestMtu(reply: Reply<Double, BleError>) {
        operations.enqueue(MtuOperation(self, reply: reply))
    }

    func discoverServices(reply: Reply<Void, BleError>) {
        operations.enqueue(DiscoveryOperation(self, reply: reply))
    }

    /// Whether `key` has an active subscription (its CCCD write confirmed, not ended or unsubscribed).
    func isSubscribed(_ key: CharacteristicKey) -> Bool {
        return subscriptions.isSubscribed(key: key)
    }

    /// The characteristic `key` names, by the lookup requests use; nil when that lookup fails (getCharacteristicProperties).
    func lookup(_ key: CharacteristicKey) -> CBCharacteristic? {
        if case .found(let characteristic) = find(key) {
            return characteristic
        }
        return nil
    }

    // MARK: - Closing (from the link)

    /**
     * Fails the running and every queued request with `error`, and every later one at once
     * (disconnect(): NativeBleNitro.nitro.ts, "fails the queued operations at once with
     * DeviceDisconnected"). The subscriptions stay until the link is down.
     *
     * Requirement: always followed by `close` when the link is down (the link's close
     * funnel). A subscribe operation this fails stays Pending (NotificationHub.finish on
     * `.queueClosed`), and only the end of the subscriptions in `close` completes it.
     */
    func closeOperations(_ error: BleError) {
        operations.close(error)
    }

    /**
     * Closes the session: requests fail with `operationError` (the operation queue first),
     * then every subscription ends with `subscriptionError` (Pending completions fail, then
     * Active `onEnded`s fire). Idempotent in effect: a stalled session is closed at the
     * stall and again by the link's close at didDisconnectPeripheral, and the second call
     * finds nothing left.
     */
    func close(operationError: BleError, subscriptionError: BleError) {
        operations.close(operationError)
        subscriptions.endAll(error: subscriptionError)
    }

    /**
     * The queue stalled on `operation`'s timeout, before the operation's failure fires
     * (it already is out of flight). The link closes this session from `onStall`: the
     * timed-out operation fails first (OperationTimedOut), then the queued requests, then
     * the subscriptions (with the stall error, NativeBleNitro.nitro.ts, "Timeouts").
     */
    private func operationTimedOut(_ operation: SessionOperation) {
        onStall(stalledError(deviceId, operation: operation.description, timeoutMs: operation.timeoutMs))
    }

    // MARK: - For the operations (GattSessionOperations.swift)

    /**
     * Requirement (NativeBleNitro.nitro.ts, "After destroy()"; BleCore.isDestroying): no
     * GATT request reaches the device once destroy() was called. destroy() posts its
     * teardown behind the deliveries already on the manager's queue, and an answer among
     * them completes the operation in flight, which starts the next one. So every path
     * that sends something to the peripheral asks this first: SessionOperation.start, the
     * write-without-response pacing and the characteristic-discovery continuation. The
     * request then fails with BluetoothManagerDestroyed, or waits for the teardown, which
     * fails it with that error.
     */
    var isManagerDestroying: Bool {
        return managerDestroying()
    }

    /// Completes `operation` if it is in flight (GattOperationQueue.complete); false when its answer came too late.
    @discardableResult
    func complete(_ operation: SessionOperation, deliver: () -> Void) -> Bool {
        return operations.complete(operation, deliver: deliver)
    }

    /// Bumped by every change of the database the subscriptions were made on (see SessionOperation.answer).
    var databaseGeneration: Int64 {
        return subscriptions.generation
    }

    /**
     * The characteristic for `key` if `access` is allowed: the lookup (`find`), then the
     * declared properties and, for a write, its length (GattRules.violation; a write
     * without response carries at most `maximumWriteValueLength(for: .withoutResponse)`).
     * Checked when the request starts: the database, the properties and the write limit
     * are those of that moment.
     */
    func resolve(_ key: CharacteristicKey, _ access: GattRules.Access) -> CharacteristicLookup {
        let lookup = find(key)
        guard case .found(let characteristic) = lookup else { return lookup }
        // CBCharacteristicProperties uses the Characteristic Declaration's property bits.
        if let violation = GattRules.violation(
            access,
            properties: characteristic.properties.rawValue,
            maxWithoutResponse: peripheral.maximumWriteValueLength(for: .withoutResponse)
        ) {
            return .failed(violationError(violation, characteristic: key.characteristic, deviceId: deviceId))
        }
        return lookup
    }

    /// The lookup part of `resolve`: 303, 302, 405, 404 in that order.
    func find(_ key: CharacteristicKey) -> CharacteristicLookup {
        guard let services = peripheral.services, !invalidatedServices.contains(key.service) else {
            return .failed(servicesNotDiscoveredError(deviceId))
        }
        guard let service = services.first(where: { $0.uuid == key.service }) else {
            return .failed(serviceNotFoundError(deviceId, service: key.service))
        }
        guard let characteristics = service.characteristics else {
            return .failed(characteristicsNotDiscoveredError(deviceId, service: key.service))
        }
        guard let characteristic = characteristics.first(where: { $0.uuid == key.characteristic }) else {
            return .failed(characteristicNotFoundError(deviceId, service: key.service, characteristic: key.characteristic))
        }
        return .found(characteristic)
    }

    /**
     * What the CCCD operation of `request` writes to `characteristic`'s descriptor
     * (NotificationHub.plan). `CBCharacteristic.isNotifying` is authoritative on iOS: a
     * characteristic restored with notifications on (state restoration), or turned on by
     * an earlier link of the same connection, needs no write.
     */
    func plan(_ request: Subscriptions.CccdRequest, for characteristic: CBCharacteristic) -> Subscriptions.CccdPlan {
        return subscriptions.plan(request, osNotifying: characteristic.isNotifying)
    }

    /// A CCCD operation's one exit (NotificationHub.finish).
    func finish(_ request: Subscriptions.CccdRequest, plan: Subscriptions.CccdPlan?, error: BleError?, cause: FailCause?) {
        subscriptions.finish(request, plan: plan, error: error, cause: cause)
    }

    /// A discovery saw the current database: the services the device changed are valid again.
    func discoveryFinished() {
        invalidatedServices.removeAll()
    }

    // MARK: - CoreBluetooth answers (from PeripheralLink)

    func didDiscoverServices(error: Error?) {
        guard let discovery = operations.current as? DiscoveryOperation else {
            return droppedAnswer("didDiscoverServices", error: error)
        }
        discovery.servicesDiscovered(error: error)
    }

    func didDiscoverCharacteristics(for service: CBService, error: Error?) {
        guard let discovery = operations.current as? DiscoveryOperation else {
            return droppedAnswer("didDiscoverCharacteristicsFor \(service.uuid.fullUUIDString)", error: error)
        }
        discovery.characteristicsDiscovered(for: service, error: error)
    }

    /**
     * The device changed its GATT database (Service Changed indication, Bluetooth Core
     * Specification Vol 3 Part G §7.1; CoreBluetooth's peripheral(_:didModifyServices:)).
     * CoreBluetooth already removed `invalidated` from `peripheral.services`; their
     * CBService and CBCharacteristic objects can't be used any more.
     *
     * In this order:
     * 1. Requests on these services fail with ServicesNotDiscovered until a discovery
     *    succeeds (`invalidatedServices`).
     * 2. Their subscriptions end with ServicesNotDiscovered (Pending completions fail,
     *    Active `onEnded`s fire), which resets their CCCD state and starts a new
     *    generation: the characteristics of a changed service are new attributes, whose
     *    CCCDs nobody wrote.
     * 3. The request in flight fails now if it targets one of them
     *    (SessionOperation.serviceChanged): its answer may never come, and a late one
     *    names an object of the old database, which the identity match drops. A discovery
     *    is never failed early (DiscoveryOperation.servicesInvalidated).
     * Requests queued behind look the characteristic up when they start, so they fail
     * through `find` without help. The link emits ServicesChanged afterwards.
     */
    func servicesModified(_ invalidated: [CBService]) {
        let changed = Set(invalidated.map { $0.uuid })
        invalidatedServices.formUnion(changed)
        subscriptions.endKeys(error: servicesChangedError(deviceId), where: { changed.contains($0.service) })
        guard let current = operations.current else { return }
        if let discovery = current as? DiscoveryOperation {
            discovery.servicesInvalidated(invalidated)
        } else if let key = current.key, changed.contains(key.service) {
            current.serviceChanged(servicesChangedError(deviceId))
        }
    }

    /**
     * A read's answer or a notification: CoreBluetooth reports both through
     * peripheral(_:didUpdateValueFor:error:) and they can't be told apart. A read waiting
     * for this characteristic completes with the first update (ReadOperation.answered).
     * Every value still goes to the subscribers, the read's answer included, so none of
     * their values is lost.
     */
    func didUpdateValue(for characteristic: CBCharacteristic, error: Error?) {
        if let read = operations.current as? ReadOperation, read.awaitsValue(of: characteristic) {
            read.answered(characteristic, error: error)
        } else if error != nil {
            droppedAnswer("didUpdateValueFor \(characteristic.uuid.fullUUIDString)", error: error)
        }
        // An update with an error has no value to deliver, and NotificationCallback has no
        // error to carry. Each subscriber gets the Data value (immutable, shared without a
        // copy); its listener, wrapped by the facade, copies it into an ArrayBuffer of its
        // own, so one subscriber changing its buffer can't change another's.
        guard error == nil, let value = characteristic.value, let service = characteristic.service else { return }
        subscriptions.deliver(key: CharacteristicKey(service: service.uuid, characteristic: characteristic.uuid), makeValue: { value })
    }

    func didWriteValue(for characteristic: CBCharacteristic, error: Error?) {
        guard let write = operations.current as? WriteOperation, write.awaitsResponse(from: characteristic) else {
            return droppedAnswer("didWriteValueFor \(characteristic.uuid.fullUUIDString)", error: error)
        }
        write.answered(error: error)
    }

    func readyToSendWriteWithoutResponse() {
        (operations.current as? WriteOperation)?.readyToSend()
    }

    func didUpdateNotificationState(for characteristic: CBCharacteristic, error: Error?) {
        guard let cccd = operations.current as? CccdOperation, cccd.awaitsAnswer(from: characteristic) else {
            return droppedAnswer("didUpdateNotificationStateFor \(characteristic.uuid.fullUUIDString)", error: error)
        }
        cccd.answered(characteristic, error: error)
    }

    func didReadRSSI(_ rssi: NSNumber, error: Error?) {
        guard let rssiRead = operations.current as? RssiOperation else {
            return droppedAnswer("didReadRSSI", error: error)
        }
        rssiRead.answered(rssi, error: error)
    }

    /**
     * An answer no operation in flight waits for: the late answer of one that timed out,
     * failed or whose service changed, or one CoreBluetooth sent unasked. It completes
     * nothing; one carrying an error is logged, since such late answers are what explains
     * a timeout.
     */
    private func droppedAnswer(_ answer: String, error: Error?) {
        guard let error else { return }
        bleLog("\(answer) on \(deviceId) answered no operation in flight; dropped: \(error.localizedDescription)")
    }
}
