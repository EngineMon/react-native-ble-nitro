import Foundation
import CoreBluetooth
import NitroModules

/**
 * One GATT request of a link, queued in its GattSession's GattOperationQueue. One
 * subclass per kind of request (the same classes as Android's GattSession.kt), each
 * holding only its own state and handling its own CoreBluetooth answer; the session
 * routes an answer to the operation in flight by its type (and, for characteristic
 * requests, by the CBCharacteristic object).
 *
 * A class, not a protocol: the queue tells operations apart by identity, and is generic
 * over one concrete operation type. Subclasses override `issue` and `report`; the base
 * class implements the GattOperation requirements once, so every operation follows the
 * same rules:
 * - It starts only on a connected peripheral (`start`).
 * - Every timeout stalls the link (`settleOnTimeout` returns false, final).
 * - Every answer goes through `answer`: completion by identity, the database check of
 *   operations that need one, and CoreBluetooth's error mapped to the operation's own
 *   failure code.
 * - Every failure reaches the caller through `report`, with the queue's cause when the
 *   queue failed it.
 */
class SessionOperation: GattOperation {
    typealias Failure = BleError

    /// The session owns the queue that holds this operation, so it outlives it.
    unowned let session: GattSession
    /// What the operation does, for error messages: "Read of characteristic X on <device>".
    let description: String
    /// The characteristic the operation targets; nil for RSSI, MTU and discovery.
    let key: CharacteristicKey?
    /// Whether an answer counts only for the database the operation started on (see `answer`).
    private let needsUnchangedDatabase: Bool
    /// The database generation when the operation started.
    private var startGeneration: Int64 = 0

    init(_ session: GattSession, description: String, key: CharacteristicKey?, needsUnchangedDatabase: Bool) {
        self.session = session
        self.description = description
        self.key = key
        self.needsUnchangedDatabase = needsUnchangedDatabase
    }

    /// Every iOS operation is answered through an ATT procedure, or completes inside `start`: Core Vol 3 Part F §3.3.3's 30 s.
    var timeoutMs: Int {
        return GattRules.attTransactionTimeoutMs
    }

    /**
     * CoreBluetooth may have dropped the link while its didDisconnectPeripheral still waits
     * behind this task on the queue. It ignores requests on a peripheral that isn't
     * connected and never answers them, so the request fails now instead of waiting for
     * the link's close.
     */
    final func start() -> BleError? {
        startGeneration = session.databaseGeneration
        if session.isManagerDestroying {
            return destroyedError()
        }
        guard session.peripheral.state == .connected else {
            return startOnLostLink()
        }
        return issue()
    }

    /**
     * Starts the operation on a link CoreBluetooth already dropped (`start`): returns the
     * error it fails with, or nil when it completed itself. By default it fails with
     * DeviceDisconnected; an operation whose outcome the spec defines for a link that went
     * down first overrides it (an unsubscribe succeeds).
     */
    func startOnLostLink() -> BleError? {
        return linkLostError(session.deviceId, cause: nil)
    }

    /**
     * Issues the request to CoreBluetooth. Returns nil when it was issued (or the
     * operation completed itself through `session.complete`), else the error the request
     * fails with (looked-up characteristic missing, GattRules violation).
     */
    func issue() -> BleError? {
        preconditionFailure("\(type(of: self)) must override issue()")
    }

    /**
     * Reports `error` to the operation's caller. `cause` is the queue's reason when the
     * queue failed the operation (`GattOperation.fail`); nil when the operation failed on
     * its own answer, or its service changed under it.
     */
    func report(_ error: BleError, cause: FailCause?) {
        preconditionFailure("\(type(of: self)) must override report(_:cause:)")
    }

    final func fail(_ error: BleError, cause: FailCause) {
        report(error, cause: cause)
    }

    /**
     * Never settles: every timeout takes the link down. An ATT transaction not answered
     * within 30 s leaves the bearer unusable (Core Vol 3 Part F §3.3.3), and CoreBluetooth
     * answers requests of one kind on one characteristic through the same delegate
     * callback, so a late answer would otherwise complete a later request with the wrong
     * result. A write without response waiting for `peripheralIsReady` has no ATT request
     * outstanding, but CoreBluetooth not making room for 30 s means the link doesn't move
     * either, so it gets the same rule. (MTU requests complete inside `start`, so they
     * never time out.)
     */
    final func settleOnTimeout() -> Bool {
        return false
    }

    /**
     * The one way CoreBluetooth's answer completes an operation: completes it if it is
     * still in flight (a late answer for an operation that timed out, failed or was closed
     * is dropped), then reports, in this order:
     * - When the operation needs an unchanged database and the device changed services
     *   since it started (a new hub generation): ServicesNotDiscovered, whatever
     *   CoreBluetooth answered (an error is logged). The answer refers to a database that
     *   is gone. Only discovery needs this on iOS: CoreBluetooth names the services it
     *   invalidates, so `GattSession.servicesModified` fails a characteristic request on
     *   one of them at once, and the identity match of answers drops their late answers;
     *   a request on an unchanged service keeps its result.
     * - `osError`: the operation's own failure code (`failCode`) with CoreBluetooth's
     *   status.
     * - Otherwise `succeed`.
     */
    final func answer(_ osError: Error?, failCode: BleErrorCode, _ succeed: () -> Void) {
        session.complete(self) {
            if needsUnchangedDatabase && session.databaseGeneration != startGeneration {
                if let osError {
                    bleLog("\(description) answered after the services changed; its answer is ignored: \(osError.localizedDescription)")
                }
                report(servicesChangedDuringError(session.deviceId, operation: description), cause: nil)
                return
            }
            if let osError {
                report(gattStatusError(failCode, description, cause: osError), cause: nil)
            } else {
                succeed()
            }
        }
    }

    /**
     * The device changed the service this operation targets while it was in flight (see
     * `GattSession.servicesModified`): it fails now with `error`, as its answer may never
     * come and a late one names an object of the old database.
     */
    func serviceChanged(_ error: BleError) {
        session.complete(self) {
            report(error, cause: nil)
        }
    }
}

/// readCharacteristic.
final class ReadOperation: SessionOperation {
    private let target: CharacteristicKey
    private let reply: Reply<ArrayBuffer, BleError>
    /// The characteristic resolved at start: answers are matched to it by identity.
    private var characteristic: CBCharacteristic?

    init(_ session: GattSession, key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) {
        self.target = key
        self.reply = reply
        super.init(
            session,
            description: "Read of characteristic \(key.characteristic.fullUUIDString) on \(session.deviceId)",
            key: key,
            needsUnchangedDatabase: false
        )
    }

    override func issue() -> BleError? {
        switch session.resolve(target, .read) {
        case .failed(let error):
            return error
        case .found(let found):
            characteristic = found
            session.peripheral.readValue(for: found)
            return nil
        }
    }

    /// Whether `update` (a didUpdateValueFor) is for this read's characteristic.
    func awaitsValue(of update: CBCharacteristic) -> Bool {
        return characteristic === update
    }

    /**
     * The first value update of the characteristic. On a notifying characteristic it may
     * be a notification that arrived before the read's answer: CoreBluetooth reports both
     * through peripheral(_:didUpdateValueFor:error:) and they can't be told apart
     * (NativeBleNitro.nitro.ts, readCharacteristic: iOS limit). The value is copied into a
     * buffer of the caller's own.
     */
    func answered(_ update: CBCharacteristic, error: Error?) {
        answer(error, failCode: .characteristicreadfailed) {
            if let value = update.value {
                reply.succeed(ArrayBuffer.copying(value))
            } else {
                report(gattStatusError(.characteristicreadfailed, description, cause: nil), cause: nil)
            }
        }
    }

    override func report(_ error: BleError, cause: FailCause?) {
        reply.fail(error)
    }
}

/// writeCharacteristic, with or without response.
final class WriteOperation: SessionOperation {
    private let target: CharacteristicKey
    /// The operation's own copy of the bytes, taken on the caller's thread when the
    /// request was made, so the caller may reuse its buffer at once.
    private let data: Data
    private let withResponse: Bool
    private let reply: Reply<ArrayBuffer, BleError>
    /// The characteristic resolved at start: answers are matched to it by identity.
    private var characteristic: CBCharacteristic?

    init(_ session: GattSession, key: CharacteristicKey, data: Data, withResponse: Bool, reply: Reply<ArrayBuffer, BleError>) {
        self.target = key
        self.data = data
        self.withResponse = withResponse
        self.reply = reply
        super.init(
            session,
            description: "Write of characteristic \(key.characteristic.fullUUIDString) on \(session.deviceId)",
            key: key,
            needsUnchangedDatabase: false
        )
    }

    /**
     * The characteristic must declare the property of the write type, and the value fit:
     * 512 bytes with response, min(maximumWriteValueLength(for: .withoutResponse), 512)
     * without (GattRules.violation).
     */
    override func issue() -> BleError? {
        switch session.resolve(target, .write(length: data.count, withResponse: withResponse)) {
        case .failed(let error):
            return error
        case .found(let found):
            characteristic = found
            if withResponse {
                session.peripheral.writeValue(data, for: found, type: .withResponse)
            } else {
                sendIfReady(to: found)
            }
            return nil
        }
    }

    /// Whether `written` (a didWriteValueFor) answers this write: only a write with response gets one.
    func awaitsResponse(from written: CBCharacteristic) -> Bool {
        return withResponse && characteristic === written
    }

    /// The Write Response. Completes with the bytes written, as on Android (CoreBluetooth has no response payload).
    func answered(error: Error?) {
        answer(error, failCode: .characteristicwritefailed) {
            reply.succeed(ArrayBuffer.copying(data))
        }
    }

    /// peripheralIsReady(toSendWriteWithoutResponse:): CoreBluetooth has room for a write without response again.
    func readyToSend() {
        // After destroy() the write waits for the teardown, which fails it (GattSession.isManagerDestroying).
        guard !withResponse, let characteristic, !session.isManagerDestroying else { return }
        sendIfReady(to: characteristic)
    }

    /**
     * A write without response completes once CoreBluetooth took it
     * (NativeBleNitro.nitro.ts, writeCharacteristic), so awaiting each write paces a
     * burst. CoreBluetooth has room for a limited number of them: while
     * `canSendWriteWithoutResponse` is false it drops further ones, so the write waits for
     * peripheralIsReady(toSendWriteWithoutResponse:) (Apple, CBPeripheral
     * canSendWriteWithoutResponse) and is sent then. The completion carries a copy of the
     * bytes: CoreBluetooth may still hold the written Data, and the caller may change the
     * buffer it gets.
     */
    private func sendIfReady(to characteristic: CBCharacteristic) {
        guard session.peripheral.canSendWriteWithoutResponse else { return }
        session.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        session.complete(self) {
            reply.succeed(ArrayBuffer.copying(data))
        }
    }

    override func report(_ error: BleError, cause: FailCause?) {
        reply.fail(error)
    }
}

/**
 * The CCCD (Client Characteristic Configuration descriptor) operation of one subscribe or
 * unsubscribe call. When it starts, the hub decides from the subscriptions, as every
 * operation queued before it left them, whether the descriptor must be written
 * (`GattSession.plan`); every exit goes through the hub's one `finish`, which records the
 * write's result and settles the operation's own caller.
 */
final class CccdOperation: SessionOperation {
    typealias Request = GattSession.Subscriptions.CccdRequest

    private let request: Request
    /// The characteristic whose CCCD write is awaited, set with `plan` when the write was issued.
    private var characteristic: CBCharacteristic?
    /// The plan of the write that was issued; nil while none was.
    private var plan: GattSession.Subscriptions.CccdPlan?

    /// The subscribe of subscriber `id` (already in the hub); its outcome settles only that subscriber.
    static func subscribe(_ session: GattSession, id: Int64, key: CharacteristicKey) -> CccdOperation {
        return CccdOperation(
            session,
            request: .subscribe(id: id, key: key),
            description: "Subscribing (id \(id)) to characteristic \(key.characteristic.fullUUIDString) on \(session.deviceId)"
        )
    }

    /// An unsubscribe whose subscriber is already removed from the hub; `reply` is the call's completion.
    static func unsubscribe(_ session: GattSession, key: CharacteristicKey, reply: Reply<Void, BleError>) -> CccdOperation {
        return CccdOperation(
            session,
            request: .unsubscribe(key: key, reply: reply),
            description: "Unsubscribing from characteristic \(key.characteristic.fullUUIDString) on \(session.deviceId)"
        )
    }

    private init(_ session: GattSession, request: Request, description: String) {
        self.request = request
        super.init(session, description: description, key: request.key, needsUnchangedDatabase: false)
    }

    /**
     * An unsubscribe on a link CoreBluetooth already dropped (its didDisconnectPeripheral
     * still on the queue) completes without error and without a write
     * (NativeBleNitro.nitro.ts, unsubscribeFromCharacteristic: "Completes without error
     * when the link goes down first"), as Android's refused CCCD write that says the link
     * is gone: its subscription is ended, and the close ends the rest. A subscribe fails
     * with DeviceDisconnected, its own outcome.
     */
    override func startOnLostLink() -> BleError? {
        guard case .unsubscribe = request else { return super.startOnLostLink() }
        bleLog("\(description): the link is going down; the subscription is ended")
        session.complete(self) {
            session.finish(request, plan: nil, error: nil, cause: nil)
        }
        return nil
    }

    override func issue() -> BleError? {
        switch request {
        case .subscribe(_, let key):
            switch session.resolve(key, .notify) {
            case .failed(let error):
                return error
            case .found(let found):
                writeIfPlanned(found)
            }
        case .unsubscribe(let key, _):
            // No property check: whatever the characteristic declares, nothing is left to
            // turn off unless it notifies.
            switch session.find(key) {
            case .failed(let error):
                // No descriptor to write, and nothing left on. On iOS the lookup of a
                // characteristic that had a subscriber fails only after the device changed
                // its service: CoreBluetooth removes a service from `peripheral.services`
                // only with didModifyServices (Apple, peripheral(_:didModifyServices:)),
                // and `GattSession.servicesModified` ends that service's subscriptions and
                // resets their tracked CCCD state at the same time; a failed discovery
                // invalidates nothing on iOS. The other case is a subscriber unsubscribed
                // before its subscribe ran (services not discovered yet): nothing was
                // ever written.
                bleLog("\(description): nothing to turn off (\(error.message)); the subscription is ended")
                session.complete(self) {
                    session.finish(request, plan: nil, error: nil, cause: nil)
                }
            case .found(let found):
                writeIfPlanned(found)
            }
        }
        return nil
    }

    /**
     * Writes the CCCD when the plan says so (`setNotifyValue`; CoreBluetooth picks
     * notifications or indications from the characteristic's properties). Otherwise the
     * operation succeeds without a write: the descriptor already has the state the
     * subscriptions need, or another subscriber still needs it on.
     */
    private func writeIfPlanned(_ found: CBCharacteristic) {
        let plan = session.plan(request, for: found)
        guard plan.write else {
            session.complete(self) {
                session.finish(request, plan: plan, error: nil, cause: nil)
            }
            return
        }
        self.characteristic = found
        self.plan = plan
        session.peripheral.setNotifyValue(plan.enable, for: found)
    }

    /// Whether `updated` (a didUpdateNotificationStateFor) answers this operation's write.
    func awaitsAnswer(from updated: CBCharacteristic) -> Bool {
        return plan != nil && characteristic === updated
    }

    /**
     * The CCCD write's answer. It succeeded only if CoreBluetooth reports no error and the
     * characteristic now notifies as planned; a failure is CharacteristicNotifyChangeFailed
     * (with the CBATTError as nativeStatus when CoreBluetooth gave one).
     */
    func answered(_ updated: CBCharacteristic, error: Error?) {
        guard let plan else { return }
        answer(error, failCode: .characteristicnotifychangefailed) {
            if updated.isNotifying != plan.enable {
                report(cccdStateMismatchError(description, notifying: updated.isNotifying), cause: nil)
            } else {
                session.finish(request, plan: plan, error: nil, cause: nil)
            }
        }
    }

    /**
     * Every failure goes to the hub with the plan of a write that was issued (its result
     * is then unknown: the device may have applied it) and the queue's cause: a subscribe
     * the queue's close failed stays Pending for the end of the subscriptions that
     * follows; an unsubscribe the queue's close failed succeeds (the link went down
     * first). See NotificationHub.finish.
     */
    override func report(_ error: BleError, cause: FailCause?) {
        session.finish(request, plan: plan, error: error, cause: cause)
    }

    /**
     * The device changed the characteristic's service while the write was in flight
     * (`GattSession.servicesModified`). A subscribe fails with `error`, a no-op for its
     * subscriber, which the change already ended. An unsubscribe succeeds, as on Android:
     * its subscription is over either way and the changed service has nothing left to turn
     * off. Either way the hub drops the write's result: the change reset the key since
     * the plan was made.
     */
    override func serviceChanged(_ error: BleError) {
        guard case .unsubscribe = request else {
            super.serviceChanged(error)
            return
        }
        session.complete(self) {
            bleLog("\(description): the service changed (\(error.message)); the subscription is ended")
            session.finish(request, plan: plan, error: nil, cause: nil)
        }
    }
}

/// readRSSI.
final class RssiOperation: SessionOperation {
    private let reply: Reply<Double, BleError>

    init(_ session: GattSession, reply: Reply<Double, BleError>) {
        self.reply = reply
        super.init(session, description: "RSSI read on \(session.deviceId)", key: nil, needsUnchangedDatabase: false)
    }

    override func issue() -> BleError? {
        session.peripheral.readRSSI()
        return nil
    }

    func answered(_ rssi: NSNumber, error: Error?) {
        answer(error, failCode: .devicerssireadfailed) {
            reply.succeed(rssi.doubleValue)
        }
    }

    override func report(_ error: BleError, cause: FailCause?) {
        reply.fail(error)
    }
}

/**
 * requestMTU. iOS negotiates the MTU by itself and has no API to request one: completes
 * with the ATT MTU in effect (`GattSession.attMtu`) when its turn comes. Queued like every
 * other request so it runs in call order: one made after discoverServices sees the MTU
 * once discovery finished (CoreBluetooth exchanges the MTU by itself shortly after
 * connecting). The caller validated the requested value (GattRules.validMtuRequest).
 */
final class MtuOperation: SessionOperation {
    private let reply: Reply<Double, BleError>

    init(_ session: GattSession, reply: Reply<Double, BleError>) {
        self.reply = reply
        super.init(session, description: "MTU request on \(session.deviceId)", key: nil, needsUnchangedDatabase: false)
    }

    override func issue() -> BleError? {
        let mtu = Double(session.attMtu)
        session.complete(self) {
            reply.succeed(mtu)
        }
        return nil
    }

    override func report(_ error: BleError, cause: FailCause?) {
        reply.fail(error)
    }
}

/**
 * discoverServices: every service, then the characteristics of every service, as on
 * Android (they are what characteristic requests look up).
 *
 * The database it saw is current only if the device changed no service while it ran: its
 * answers need an unchanged database (`answer`), so a discovery that overlapped a
 * didModifyServices fails with ServicesNotDiscovered, also when CoreBluetooth answered it
 * with an error, and the changed services stay invalid until a discovery that overlaps no
 * change.
 *
 * Known limit: a characteristic discovery that failed leaves the other services'
 * discoverCharacteristics calls outstanding. If the next discovery asks the same CBService
 * objects again (their characteristics still nil), a late error answer of the failed one
 * can fail it; CoreBluetooth's answers don't say which request they answer.
 */
final class DiscoveryOperation: SessionOperation {
    private enum Phase {
        /// discoverServices was issued.
        case services
        /// The services whose characteristics are still coming.
        case characteristics([CBService])
    }

    private let reply: Reply<Void, BleError>
    private var phase = Phase.services

    init(_ session: GattSession, reply: Reply<Void, BleError>) {
        self.reply = reply
        super.init(session, description: "Service discovery on \(session.deviceId)", key: nil, needsUnchangedDatabase: true)
    }

    override func issue() -> BleError? {
        session.peripheral.discoverServices(nil)
        return nil
    }

    /**
     * peripheral(_:didDiscoverServices:). Only services without characteristics are asked:
     * CoreBluetooth may skip didDiscoverCharacteristicsFor for a service whose
     * characteristics it has cached, which would leave the request waiting.
     */
    func servicesDiscovered(error: Error?) {
        guard case .services = phase else { return }
        guard error == nil else {
            return answer(error, failCode: .servicesdiscoveryfailed, succeed)
        }
        // After destroy() no request goes out: the teardown fails the discovery (GattSession.isManagerDestroying).
        guard !session.isManagerDestroying else { return }
        let waiting = (session.peripheral.services ?? []).filter { $0.characteristics == nil }
        guard !waiting.isEmpty else {
            return answer(nil, failCode: .servicesdiscoveryfailed, succeed)
        }
        phase = .characteristics(waiting)
        for service in waiting {
            session.peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    /// peripheral(_:didDiscoverCharacteristicsFor:error:) for one of the services asked.
    func characteristicsDiscovered(for service: CBService, error: Error?) {
        guard case .characteristics(var waiting) = phase,
              let index = waiting.firstIndex(where: { $0 === service }) else { return }
        guard error == nil else {
            return answer(error, failCode: .characteristicsdiscoveryfailed, succeed)
        }
        waiting.remove(at: index)
        phase = .characteristics(waiting)
        if waiting.isEmpty {
            answer(nil, failCode: .characteristicsdiscoveryfailed, succeed)
        }
    }

    /**
     * The device invalidated `invalidated` while this discovery ran. A discovery is never
     * failed early: CoreBluetooth answers discoverServices without saying which request it
     * answers, so a discovery taken out of flight early could have its late answer
     * complete the next discovery. It runs to its end and fails through the database
     * check of `answer`. Once past didDiscoverServices it stops waiting for the
     * characteristics of invalidated services (their late answers name old objects).
     *
     * By UUID, not identity: the services waited for are the ones the database held when
     * didDiscoverServices ran, and Apple doesn't document that the invalidated CBService
     * objects are those same instances. With two services of one UUID this also drops a
     * valid one, harmless: the database check fails this discovery anyway.
     */
    func servicesInvalidated(_ invalidated: [CBService]) {
        guard case .characteristics(var waiting) = phase else { return }
        let changed = Set(invalidated.map { $0.uuid })
        waiting.removeAll { changed.contains($0.uuid) }
        phase = .characteristics(waiting)
        if waiting.isEmpty {
            answer(nil, failCode: .characteristicsdiscoveryfailed, succeed)
        }
    }

    /// The discovery saw the current database: the services it changed are valid again.
    private func succeed() {
        session.discoveryFinished()
        reply.succeed()
    }

    override func report(_ error: BleError, cause: FailCause?) {
        reply.fail(error)
    }
}
