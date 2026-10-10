import Foundation
import CoreBluetooth
import NitroModules

/// What a link needs from the manager that owns it, on the manager's queue.
protocol LinkOwner: AnyObject {
    /**
     * The central while the manager may start OS work: nil once destroy() was called (or
     * before a central exists). Every connect attempt and cancel of a link goes through
     * it, so none starts after destroy() (NativeBleNitro.nitro.ts, "After destroy()").
     */
    var liveCentral: CBCentralManager? { get }

    /**
     * True from the destroy() call on. Every GATT request asks it before it is issued
     * (GattSession.isManagerDestroying): the teardown runs only after the deliveries
     * already on the queue, and an answer among them would otherwise start the next queued
     * request on the device, while its caller is told BluetoothManagerDestroyed.
     */
    var isDestroying: Bool { get }

    /**
     * Emits `event` to the connection-event observers. A link calls it at its point of a
     * transition's firing order, after its state changed: Connected right before the
     * connect's success, Disconnected last of a close, ServicesChanged after the session
     * ended the affected subscriptions.
     */
    func connectionEvent(_ event: ConnectionEvent)
}

/**
 * Why a link closes: the one input of the close funnel (`PeripheralLink.takeDown`), which
 * derives every error of the close from it (`outcome`). The same cases as Android's
 * LinkEnd. On iOS the link stays, one per peripheral, after a close: it is ready for the
 * next connect().
 */
enum LinkEnd {
    /// The attempt ended before the link was up (didFailToConnect, or its didDisconnectPeripheral).
    case connectFailed(BleError)
    /// The OS reported the link down without disconnect() asking for it; the error didDisconnectPeripheral carried.
    case lost(Error?)
    /// The link went down after disconnect().
    case disconnected
    /// An operation timed out and took the link down; the stall error (OperationTimedOut, naming the operation).
    case stalled(BleError)
    /// Bluetooth left the powered-on state, which ends every link without a didDisconnectPeripheral; that state's error.
    case bluetoothUnavailable(BleError)
    case destroyed

    /// The errors and report of one close (see `outcome`).
    struct Outcome {
        /// What a pending connect fails with; nil when the close isn't its end (a connect waiting for the link to go down starts then).
        let connect: BleError?
        /// What the operations still queued fail with.
        let operations: BleError
        /// What the subscriptions end with.
        let subscriptions: BleError
        /// What the waiting disconnect() calls fail with; nil: they succeed (the link is down, as asked).
        let disconnects: BleError?
        /// The disconnect callback's and the Disconnected event's `interrupted`.
        let interrupted: Bool
        /// Their error: why an interrupted link went down; nil when it wasn't interrupted.
        let reason: BleError?
    }

    /**
     * Every error of a close of `deviceId`'s link, decided in one place
     * (NativeBleNitro.nitro.ts, "When a link goes down", "Timeouts", "After destroy()",
     * DisconnectionEventCallback, SubscriptionEndedCallback):
     * - lost: everything DeviceDisconnected with CoreBluetooth's status, interrupted.
     * - disconnected: DeviceDisconnected, not interrupted, the disconnect() calls succeed.
     * - stalled: queued operations DeviceDisconnected, subscriptions and the report the
     *   stall error (OperationTimedOut), interrupted.
     * - bluetoothUnavailable: a pending connect fails with the state's error, the link's
     *   operations and subscriptions with DeviceDisconnected, interrupted.
     * - destroyed: everything BluetoothManagerDestroyed; listeners are silenced by then,
     *   so the report is not interrupted and only completions fire.
     */
    func outcome(deviceId: String) -> Outcome {
        switch self {
        case .connectFailed(let error):
            return Outcome(connect: error, operations: error, subscriptions: error, disconnects: nil, interrupted: true, reason: error)
        case .lost(let cause):
            let lost = linkLostError(deviceId, cause: cause)
            return Outcome(connect: nil, operations: lost, subscriptions: lost, disconnects: nil, interrupted: true, reason: lost)
        case .disconnected:
            let down = disconnectedError(deviceId)
            return Outcome(connect: nil, operations: down, subscriptions: down, disconnects: nil, interrupted: false, reason: nil)
        case .stalled(let cause):
            return Outcome(
                connect: nil,
                operations: stalledLinkError(deviceId),
                subscriptions: cause,
                disconnects: nil,
                interrupted: true,
                reason: cause
            )
        case .bluetoothUnavailable(let unavailable):
            let lost = bluetoothOffLinkLostError(deviceId, unavailable)
            return Outcome(connect: unavailable, operations: lost, subscriptions: lost, disconnects: nil, interrupted: true, reason: lost)
        case .destroyed:
            let destroyed = destroyedError()
            return Outcome(
                connect: destroyed,
                operations: destroyed,
                subscriptions: destroyed,
                disconnects: destroyed,
                interrupted: false,
                reason: nil
            )
        }
    }
}

/**
 * One peripheral this manager uses, and its link: the peripheral's CBPeripheralDelegate
 * (CoreBluetooth has one delegate per peripheral) and the connect/disconnect state
 * machine. The manager keeps exactly one per peripheral, as long as the peripheral object
 * is valid, so the state spans attempts and links: CoreBluetooth reports an attempt's
 * outcome late and in order per peripheral. Runs on the manager's queue only.
 *
 * State (`state`, one value, so no combination of flags can contradict another):
 * - idle: no link of this manager, no connect waiting.
 * - connecting: a connect() waits for the attempt it issued or took over.
 * - up: this manager's link is up, with its GattSession (requests, subscriptions).
 * - goingDown: the link (or a connected peripheral this manager never adopted) goes down,
 *   for one `Closing` reason; its didDisconnectPeripheral closes it. A connect() made
 *   meanwhile waits there (`next`) and starts once it is down: adopting a link that is
 *   going down would hand the caller a link that drops at once (a timed-out link may not
 *   carry another ATT request, Bluetooth Core Specification Vol 3 Part F §3.3.3).
 *
 * Every close goes through one funnel, `takeDown(LinkEnd)`: it changes state only and
 * returns the firing, which runs in the order NativeBleNitro.nitro.ts fixes for a close (a
 * pending connect that fails with it, the queued operations, the subscriptions, the
 * disconnect() calls, the disconnect callback, last the Disconnected event). Collect,
 * then fire: a callback that reads the link inline (isConnected, a C++ callback calling a
 * synchronous getter) sees it down already. `closeAll` closes many links that way, with
 * every state change before the first firing.
 *
 * CoreBluetooth's answers go to the link's session while it has one (up or going down);
 * with none they belong to no request of this manager and are dropped.
 */
final class PeripheralLink: NSObject, CBPeripheralDelegate {
    /// A connect() waiting for its link to come up.
    private final class PendingConnect {
        enum Attempt {
            /**
             * No attempt started for it yet: it is about to be issued, or waits for the
             * peripheral's previous link to finish going down (`State.goingDown`'s `next`).
             */
            case notStarted
            /// This manager started the attempt (central.connect): its timeout cancels it.
            case issued
            /**
             * CoreBluetooth already had an attempt pending that this manager didn't start: a
             * connection iOS restored, or one an earlier manager left behind. It isn't this
             * call's to cancel: its timeout fails only the call, and the attempt goes on
             * (NativeBleNitro.nitro.ts, connect).
             */
            case takenOver
        }

        let reply: Reply<Void, BleError>
        /// Installed on the link once it is up: only a link that came up reports its drop.
        let onDisconnect: Once<ConnectionEvent>?
        var attempt: Attempt
        /// Fires after ConnectOptions.timeoutMs.
        var timeout: DispatchWorkItem?

        init(reply: Reply<Void, BleError>, onDisconnect: Once<ConnectionEvent>?, attempt: Attempt) {
            self.reply = reply
            self.onDisconnect = onDisconnect
            self.attempt = attempt
        }
    }

    /// Why a link goes down (`State.goingDown`).
    private enum Closing {
        /// disconnect() asked for it: its drop is not interrupted.
        case disconnectRequested
        /// An operation timed out (the stall error): the session is closed already.
        case stalled(BleError)
        /**
         * An attempt this manager cancelled connected anyway (its didConnect was already on
         * its way when the cancel ran). It is cancelled again (`cancelAgain`), so its
         * report is always owed; that report is the cancelled attempt's (counted again in
         * `cancelledAttempts`).
         */
        case cancelledAttemptConnected
        /**
         * CoreBluetooth reports the peripheral not connected (it dropped the link, or
         * someone else is disconnecting it) while its didDisconnectPeripheral hasn't run.
         */
        case osDisconnecting
    }

    private final class GoingDown {
        var why: Closing
        /// The link's session; nil for a peripheral that was never this manager's link.
        let session: GattSession?
        let onDisconnect: Once<ConnectionEvent>?
        /// disconnect() calls waiting for the link to go down.
        var disconnects: [Reply<Void, BleError>]
        /// A connect() waiting for the link to go down (`.notStarted`).
        var next: PendingConnect?

        init(why: Closing, session: GattSession?, onDisconnect: Once<ConnectionEvent>?, disconnects: [Reply<Void, BleError>] = []) {
            self.why = why
            self.session = session
            self.onDisconnect = onDisconnect
            self.disconnects = disconnects
        }
    }

    private final class Up {
        let session: GattSession
        /// connect()'s disconnect callback, while the link it brought up (or adopted) is up.
        var onDisconnect: Once<ConnectionEvent>?

        init(session: GattSession, onDisconnect: Once<ConnectionEvent>?) {
            self.session = session
            self.onDisconnect = onDisconnect
        }
    }

    private enum State {
        case idle
        case connecting(PendingConnect)
        case up(Up)
        case goingDown(GoingDown)
    }

    let peripheral: CBPeripheral
    /// The canonical device id: the peripheral's uppercase UUID.
    let deviceId: String

    private weak var owner: LinkOwner?
    /// The manager's queue: every delegate call, session timer and connect timeout runs on it.
    private let queue: DispatchQueue
    private var state = State.idle

    /**
     * Connect attempts cancelled after their caller was answered (the connect timed out, or
     * disconnect() while connecting). Apple's cancelPeripheralConnection documentation says
     * the app then considers the peripheral disconnected and the central reports it
     * through didDisconnectPeripheral. That report may arrive after connect() was called
     * again: it belongs to the old attempt and must not fail the new one, so it is counted
     * off here (`consumeCancelledAttemptReport`). Nothing guarantees the report arrives at
     * all, so the count may also go stale.
     *
     * Only a report without error is counted off: didDisconnectPeripheral carries an error
     * exactly when cancelPeripheralConnection did not initiate the disconnection (Apple,
     * centralManager(_:didDisconnectPeripheral:error:)), and didFailToConnect reports that
     * a connection failed to complete (Apple, centralManager(_:didFailToConnect:error:));
     * neither is a cancellation's report. Requirement: a stale count must never swallow a
     * genuine failure of a later attempt. If didFailToConnect, or a didDisconnectPeripheral
     * with an error, were counted off too, a count left by a cancelled attempt that was
     * never reported would take the next real failure for that report: the attempt would
     * be issued again silently and its caller would never hear of the failure.
     *
     * Reset when a link comes up (CoreBluetooth reports a peripheral's events in order, so
     * nothing from an earlier attempt can still come) and when Bluetooth leaves poweredOn
     * (CoreBluetooth ended every attempt with the radio); that also bounds it.
     */
    private var cancelledAttempts = 0

    init(peripheral: CBPeripheral, queue: DispatchQueue, owner: LinkOwner) {
        self.peripheral = peripheral
        self.deviceId = peripheral.identifier.uuidString
        self.queue = queue
        self.owner = owner
        super.init()
        peripheral.delegate = self
    }

    // MARK: - State (for the manager)

    /**
     * Whether this manager's link is up: connect() brought it up or adopted it, no timeout
     * or disconnect() is taking it down, and CoreBluetooth holds it connected (it may have
     * dropped it while its didDisconnectPeripheral still waits on the queue).
     */
    var isUp: Bool {
        return upSession != nil
    }

    /// The session of the link while it is up (`isUp`): every request and getter of the link goes through it. Its queue is open.
    var upSession: GattSession? {
        guard case .up(let up) = state, peripheral.state == .connected else { return nil }
        return up.session
    }

    /// The session of the link while it has one, up or going down (its subscriptions can still be ended).
    private var session: GattSession? {
        switch state {
        case .up(let up): return up.session
        case .goingDown(let down): return down.session
        case .idle, .connecting: return nil
        }
    }

    /// Clears the peripheral's delegate: the manager forgets the peripheral (its object is no longer valid, or destroy()).
    func release() {
        peripheral.delegate = nil
    }

    // MARK: - Connecting

    /**
     * connect() for this peripheral (NativeBleNitro.nitro.ts, connect), once Bluetooth is
     * on:
     * - A connect is pending: fails with DeviceAlreadyConnected; the pending one goes on.
     * - The link is up: succeeds at once. A present `onDisconnect` replaces the installed
     *   one, an absent one keeps it. No second Connected event: the link already
     *   announced itself.
     * - The peripheral is connected but not this manager's link (iOS restored it, or an
     *   attempt the system kept pending connected with no connect waiting): adopted at
     *   once, Connected fires right before the success.
     * - The link is going down (an operation timed out, disconnect() was called, an attempt
     *   this manager cancelled connected anyway, or CoreBluetooth reports it not
     *   connected): the connect waits for its didDisconnectPeripheral, then starts a fresh
     *   attempt.
     * - Otherwise the attempt starts, or an attempt CoreBluetooth already has pending is
     *   taken over (`PendingConnect.Attempt.takenOver`).
     * - `deadline`: fails the call with OperationTimedOut, and cancels the attempt if this
     *   connect started it. It counts from here, so a permission prompt the user hadn't
     *   answered while the manager waited for Bluetooth didn't use it up.
     */
    func connect(deadline: GattRules.ConnectDeadline, reply: Reply<Void, BleError>, onDisconnect: Once<ConnectionEvent>?) {
        switch state {
        case .connecting:
            reply.fail(alreadyConnectingError(deviceId))
        case .goingDown(let down):
            guard down.next == nil else {
                return reply.fail(alreadyConnectingError(deviceId))
            }
            let pending = PendingConnect(reply: reply, onDisconnect: onDisconnect, attempt: .notStarted)
            down.next = pending
            arm(deadline, for: pending)
        case .up(let up):
            guard peripheral.state == .connected else {
                // Dropped by CoreBluetooth; its didDisconnectPeripheral is on its way.
                let down = GoingDown(why: .osDisconnecting, session: up.session, onDisconnect: up.onDisconnect)
                state = .goingDown(down)
                return connect(deadline: deadline, reply: reply, onDisconnect: onDisconnect)
            }
            if let onDisconnect {
                up.onDisconnect = onDisconnect
            }
            reply.succeed()
        case .idle:
            switch peripheral.state {
            case .connected:
                linkUp(onDisconnect: onDisconnect)
                reply.succeed()
            case .disconnecting:
                state = .goingDown(GoingDown(why: .osDisconnecting, session: nil, onDisconnect: nil))
                connect(deadline: deadline, reply: reply, onDisconnect: onDisconnect)
            default:
                let pending = PendingConnect(reply: reply, onDisconnect: onDisconnect, attempt: .notStarted)
                arm(deadline, for: pending)
                issue(pending)
            }
        }
    }

    /**
     * Starts the attempt of `pending` and makes it the one the link waits for, unless
     * CoreBluetooth already has one going: then that attempt is taken over, unless it is
     * this connect's own (`.issued` before, re-issued after a cancelled attempt's report).
     * Without a live central nothing starts and the connect fails with
     * BluetoothManagerDestroyed; the manager forwards no central report once destroy() was
     * called, so this is only a guard against starting OS work after it.
     */
    private func issue(_ pending: PendingConnect) {
        guard let central = owner?.liveCentral else {
            state = .idle
            pending.timeout?.cancel()
            pending.reply.fail(destroyedError())
            return
        }
        state = .connecting(pending)
        if peripheral.state == .connecting {
            if case .notStarted = pending.attempt {
                pending.attempt = .takenOver
            }
            return
        }
        pending.attempt = .issued
        central.connect(peripheral, options: nil)
    }

    /// GattRules.connectDeadline bounds `ms` to 1...Int32.max, so the conversions can't trap.
    private func arm(_ deadline: GattRules.ConnectDeadline, for pending: PendingConnect) {
        guard case .after(let ms) = deadline else { return }
        let timeout = DispatchWorkItem { [weak self, weak pending] in
            guard let self, let pending else { return }
            self.connectTimedOut(pending, after: ms)
        }
        pending.timeout = timeout
        queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: timeout)
    }

    /**
     * Fails `pending` with OperationTimedOut if it still waits. Only an attempt this connect
     * started is cancelled (`Attempt.issued`); its late report is told apart from the next
     * connect's (`cancelledAttempts`).
     */
    private func connectTimedOut(_ pending: PendingConnect, after ms: Int) {
        switch state {
        case .connecting(let waiting) where waiting === pending:
            state = .idle
            if pending.attempt == .issued {
                cancelAttempt()
            }
        case .goingDown(let down) where down.next === pending:
            down.next = nil
        default:
            return
        }
        pending.reply.fail(connectTimedOutError(deviceId, timeoutMs: ms))
    }

    /// Cancels an attempt whose caller is answered: its late didDisconnectPeripheral is counted off (`cancelledAttempts`).
    private func cancelAttempt() {
        guard let central = owner?.liveCentral else { return }
        cancelledAttempts += 1
        central.cancelPeripheralConnection(peripheral)
    }

    /// The link is up (didConnect, or an adoption): a new session, then Connected.
    private func linkUp(onDisconnect: Once<ConnectionEvent>?) {
        let session = GattSession(
            peripheral: peripheral,
            deviceId: deviceId,
            queue: queue,
            isManagerDestroying: { [weak self] in self?.owner?.isDestroying ?? true },
            onStall: { [weak self] cause in self?.stalled(cause) }
        )
        state = .up(Up(session: session, onDisconnect: onDisconnect))
        owner?.connectionEvent(ConnectionEvent(deviceId: deviceId, type: .connected, interrupted: false, error: nil))
    }

    // MARK: - Disconnecting

    /**
     * disconnect() for this peripheral (NativeBleNitro.nitro.ts, disconnect):
     * - A pending connect fails with OperationCancelled and its attempt is cancelled, also
     *   an attempt the system kept pending (disconnect() is the caller's explicit request
     *   to drop the device). The call then completes at once: CoreBluetooth reports a
     *   cancelled attempt at most through a late didDisconnectPeripheral, which is told
     *   apart from the next connect's (`cancelledAttempts`).
     * - A link that is up: the queued operations fail at once with DeviceDisconnected,
     *   then the call completes at its didDisconnectPeripheral, where the subscriptions end
     *   with DeviceDisconnected and the disconnect callback gets interrupted = false. A
     *   restored link that is connected but not adopted goes down too.
     * - A link going down: the call joins it, and completes when it is down.
     * - A link an operation timeout is taking down is no longer this manager's:
     *   DeviceNotConnected (as on Android, where the stall unregisters it at once); its
     *   close still reports OperationTimedOut. A connect waiting for it is cancelled as
     *   above, and the call succeeds.
     * - Nothing to disconnect: DeviceNotConnected.
     */
    func disconnect(reply: Reply<Void, BleError>) {
        var cancelled: PendingConnect?
        /// The session whose queued operations fail now (its link goes down as asked).
        var closing: GattSession?
        var answer: (() -> Void)?
        switch state {
        case .idle:
            answer = dropUnadopted(reply, cancelledConnect: false)
        case .connecting(let pending):
            state = .idle
            cancelled = pending
            answer = dropUnadopted(reply, cancelledConnect: true)
        case .up(let up):
            state = .goingDown(GoingDown(why: .disconnectRequested, session: up.session, onDisconnect: up.onDisconnect, disconnects: [reply]))
            closing = up.session
            if peripheral.state == .connected {
                owner?.liveCentral?.cancelPeripheralConnection(peripheral)
            }
        case .goingDown(let down):
            cancelled = down.next
            down.next = nil
            switch down.why {
            case .stalled:
                let deviceId = self.deviceId
                answer = cancelled == nil ? { reply.fail(notConnectedError(deviceId)) } : { reply.succeed() }
            case .osDisconnecting:
                // Asked for now: not interrupted at its report, and never adopted again.
                down.why = .disconnectRequested
                down.disconnects.append(reply)
                closing = down.session
            case .disconnectRequested, .cancelledAttemptConnected:
                // One cancel per link: a later disconnect() joins the one going down.
                down.disconnects.append(reply)
            }
        }
        cancelled?.timeout?.cancel()
        // Collect, then fire: the cancelled connect, then the queued operations, then the answer.
        cancelled?.reply.fail(connectCancelledError(deviceId))
        closing?.closeOperations(disconnectingError(deviceId))
        answer?()
    }

    /**
     * disconnect() with no link of this manager up: drops what CoreBluetooth holds of the
     * peripheral. Returns the answer to fire now, or nil when the call waits for
     * didDisconnectPeripheral. `cancelledConnect`: the call cancelled a pending connect
     * (it succeeds even when nothing else was left to drop).
     */
    private func dropUnadopted(_ reply: Reply<Void, BleError>, cancelledConnect: Bool) -> (() -> Void)? {
        switch peripheral.state {
        case .connected:
            state = .goingDown(GoingDown(why: .disconnectRequested, session: nil, onDisconnect: nil, disconnects: [reply]))
            owner?.liveCentral?.cancelPeripheralConnection(peripheral)
            return nil
        case .disconnecting:
            state = .goingDown(GoingDown(why: .disconnectRequested, session: nil, onDisconnect: nil, disconnects: [reply]))
            return nil
        case .connecting:
            cancelAttempt()
            return { reply.succeed() }
        default:
            if cancelledConnect {
                return { reply.succeed() }
            }
            let deviceId = self.deviceId
            return { reply.fail(notConnectedError(deviceId)) }
        }
    }

    /**
     * Ends subscription `id` if this link has it, up or going down (NativeBleNitro.nitro.ts,
     * unsubscribeFromCharacteristic); see GattSession.unsubscribe. On a link going down
     * its CCCD operation fails with the closed queue and the call succeeds.
     */
    func unsubscribe(id: Int64, reply: Reply<Void, BleError>) -> Bool {
        return session?.unsubscribe(id: id, reply: reply) ?? false
    }

    /**
     * Whether `key` has an Active subscription on this link (NativeBleNitro.nitro.ts,
     * isSubscribedToCharacteristic), up or going down, as Android's
     * GattConnection.isSubscribed: an Active subscriber is reported while the link goes
     * down after disconnect(), because Active subscriptions keep receiving notifications
     * until it is down; the close ends them.
     */
    func isSubscribed(_ key: CharacteristicKey) -> Bool {
        return session?.isSubscribed(key) ?? false
    }

    // MARK: - Operation timeout

    /**
     * An operation of the up link timed out (`GattSession`'s stall hook), so the link goes
     * down: after an ATT transaction timed out no further ATT request may be sent on that
     * bearer (Bluetooth Core Specification Vol 3 Part F §3.3.3), and since no request of
     * this link ever runs again, a late answer can't complete a later request.
     *
     * State first, then callbacks: the queue calls this before the timed-out request's
     * failure fires. The link is marked going down and its connection cancelled (not a
     * cancelled attempt: the link was up, so its report is the link's own close), then
     * the session closes at once rather than at didDisconnectPeripheral: the timed-out
     * request fails with OperationTimedOut, queued requests with DeviceDisconnected, and
     * the subscriptions end with `cause`. So the first callback of the timeout already
     * sees the link down, and a notification that arrives between the cancel and
     * didDisconnectPeripheral reaches no subscriber. The disconnect callback hears `cause`
     * at didDisconnectPeripheral (`LinkEnd.stalled`).
     *
     * Only a session with an open queue can stall: the up one, or one CoreBluetooth
     * dropped before its report (`osDisconnecting`). A session taken down was closed in
     * the same queue task, which cancelled its timeout.
     */
    private func stalled(_ cause: BleError) {
        let session: GattSession
        switch state {
        case .up(let up):
            session = up.session
            state = .goingDown(GoingDown(why: .stalled(cause), session: up.session, onDisconnect: up.onDisconnect))
        case .goingDown(let down):
            guard case .osDisconnecting = down.why, let downSession = down.session else { return }
            session = downSession
            down.why = .stalled(cause)
        case .idle, .connecting:
            return
        }
        if peripheral.state == .connected {
            owner?.liveCentral?.cancelPeripheralConnection(peripheral)
        }
        let outcome = LinkEnd.stalled(cause).outcome(deviceId: deviceId)
        session.close(operationError: outcome.operations, subscriptionError: outcome.subscriptions)
    }

    // MARK: - The central's reports (forwarded by the manager)

    /**
     * The link is up. A pending connect succeeds (Connected first, in the same task).
     * Otherwise, with no connect waiting:
     * - A cancelled attempt counted: it is that attempt winning the race against its
     *   cancel; not kept, cancelled again (`cancelledAttemptConnected`, `cancelAgain`,
     *   counted again so its report isn't taken for the end of a connect issued meanwhile).
     *   A connect waiting for a link down starts at that report.
     * - None counted: an attempt the system kept pending (restored, or taken over by a
     *   connect that timed out) connected; the link is kept, so the next connect() succeeds
     *   at once, and Connected tells the app it exists. A connect waiting for the
     *   peripheral's previous link to go down (`osDisconnecting` without a session) adopts
     *   it.
     */
    func didConnect() {
        // CoreBluetooth reports a peripheral's events in order: nothing from an earlier,
        // cancelled attempt can still come.
        let hadCancelledAttempts = cancelledAttempts > 0
        cancelledAttempts = 0
        switch state {
        case .connecting(let pending):
            pending.timeout?.cancel()
            linkUp(onDisconnect: pending.onDisconnect)
            pending.reply.succeed()
        case .idle:
            if hadCancelledAttempts {
                cancelledAttempts = 1
                state = .goingDown(GoingDown(why: .cancelledAttemptConnected, session: nil, onDisconnect: nil))
                cancelAgain()
            } else {
                linkUp(onDisconnect: nil)
            }
        case .goingDown(let down):
            guard down.session == nil, case .osDisconnecting = down.why else { return }
            if hadCancelledAttempts {
                cancelledAttempts = 1
                down.why = .cancelledAttemptConnected
                cancelAgain()
            } else {
                let next = down.next
                next?.timeout?.cancel()
                linkUp(onDisconnect: next?.onDisconnect)
                next?.reply.succeed()
            }
        case .up:
            return
        }
    }

    /**
     * Cancels the link that came up as `cancelledAttemptConnected`, so a
     * didDisconnectPeripheral is always owed for it. The cancel of the attempt may still
     * be outstanding (then this one is a no-op for CoreBluetooth), but the count can be
     * stale (a cancel's report never came): then this link is an attempt the OS kept
     * pending, and without a cancel of its own it would stay connected, the link would
     * wait in goingDown forever, and a connect or disconnect waiting for its report would
     * never complete. The report that ends it is counted off as the cancelled attempt's
     * (`cancelledAttempts` is 1 again), so it fails no connect.
     */
    private func cancelAgain() {
        owner?.liveCentral?.cancelPeripheralConnection(peripheral)
    }

    /**
     * A connect attempt failed. Always the attempt in flight: CoreBluetooth reports a
     * cancelled attempt only through didDisconnectPeripheral (cancelPeripheralConnection's
     * documentation), so a failure here is never counted off as a cancelled attempt's
     * report, and a stale count can't swallow it.
     */
    func didFailToConnect(error: Error?) {
        guard case .connecting = state else { return }
        takeDown(.connectFailed(connectionFailedError(deviceId, cause: error)))()
    }

    /**
     * The peripheral is down. Which close it is follows from the state:
     * - connecting: the attempt went down before it came up, unless it is the late report
     *   of a cancelled attempt (`cancelledAttempts`): then the pending connect goes on, and
     *   is issued again since CoreBluetooth may have ended its attempt along with the
     *   cancelled one.
     * - up: lost.
     * - goingDown: as its reason says (disconnected, stalled, or lost); a connect waiting
     *   for it starts now.
     */
    func didDisconnect(error: Error?) {
        switch state {
        case .idle:
            _ = consumeCancelledAttemptReport(error)
        case .connecting(let pending):
            if consumeCancelledAttemptReport(error) {
                issue(pending)
            } else {
                takeDown(.connectFailed(connectionFailedError(deviceId, cause: error)))()
            }
        case .up:
            takeDown(.lost(error))()
        case .goingDown(let down):
            switch down.why {
            case .disconnectRequested:
                takeDown(.disconnected)()
            case .stalled(let cause):
                takeDown(.stalled(cause))()
            case .cancelledAttemptConnected:
                _ = consumeCancelledAttemptReport(error)
                takeDown(.lost(error))()
            case .osDisconnecting:
                takeDown(.lost(error))()
            }
        }
    }

    /**
     * Whether a didDisconnectPeripheral carrying `error` is the late report of a cancelled
     * attempt (see `cancelledAttempts`); counts it off if so. Only a report without an error
     * can be.
     */
    private func consumeCancelledAttemptReport(_ error: Error?) -> Bool {
        guard cancelledAttempts > 0, error == nil else { return false }
        cancelledAttempts -= 1
        return true
    }

    // MARK: - Closing

    /**
     * Closes every link in `links` for `end` (Bluetooth left poweredOn, destroy()): every
     * link's state changes first, then `finishingState` (the manager's own state change,
     * e.g. forgetting the peripherals; it must not fire callbacks), then every link's
     * callbacks fire. A callback of one link that reads another link inline sees it down
     * already. Bluetooth leaving poweredOn also ends every attempt, so no late report of a
     * cancelled one is owed.
     */
    static func closeAll(_ links: [PeripheralLink], _ end: LinkEnd, finishingState: () -> Void) {
        let firings = links.map { link -> () -> Void in
            if case .bluetoothUnavailable = end {
                link.cancelledAttempts = 0
            }
            return link.takeDown(end)
        }
        finishingState()
        for fire in firings {
            fire()
        }
    }

    /**
     * The close funnel: takes the link down for `end`, changing state only, and returns
     * the firing, which the caller must run in the same queue task (`closeAll`, or
     * `takeDown(end)()`). Until it runs the taken session is detached but still open, its
     * operation timeout armed; only because no other task can run in between can that
     * timeout never fire into a session that is no longer the link's.
     *
     * A connect waiting for the link to go down starts when the close isn't its end
     * (`Outcome.connect` nil: lost, disconnected, stalled); `issue` is OS work, not a
     * callback, so it belongs to the state phase.
     *
     * The firing order (NativeBleNitro.nitro.ts, "When a link goes down"): the pending
     * connect that fails with the close, the queued operations and the subscriptions
     * (GattSession.close), the disconnect() calls, the disconnect callback, and last the
     * Disconnected event, only for a link that announced Connected (it had a session),
     * with the disconnect callback's `interrupted` and error. A link disconnect() or an
     * operation timeout took down keeps that reason when Bluetooth turns off before its
     * report.
     */
    private func takeDown(_ end: LinkEnd) -> () -> Void {
        let outcome = end.outcome(deviceId: deviceId)
        let taken = state
        state = .idle
        var failedConnect: PendingConnect?
        var session: GattSession?
        var onDisconnect: Once<ConnectionEvent>?
        var disconnects: [Reply<Void, BleError>] = []
        var interrupted = outcome.interrupted
        var reason = outcome.reason
        switch taken {
        case .idle:
            break
        case .connecting(let pending):
            failedConnect = pending
        case .up(let up):
            session = up.session
            onDisconnect = up.onDisconnect
        case .goingDown(let down):
            session = down.session
            onDisconnect = down.onDisconnect
            disconnects = down.disconnects
            if outcome.connect == nil {
                if let next = down.next {
                    issue(next)
                }
            } else {
                failedConnect = down.next
            }
            // A link disconnect() or an operation timeout took down keeps that reason, also
            // when Bluetooth turned off before its report (destroy() reports nothing).
            switch (end, down.why) {
            case (.destroyed, _):
                break
            case (_, .stalled(let cause)):
                interrupted = true
                reason = cause
            case (_, .disconnectRequested):
                interrupted = false
                reason = nil
            case (_, .cancelledAttemptConnected), (_, .osDisconnecting):
                break
            }
        }
        failedConnect?.timeout?.cancel()
        let event = ConnectionEvent(deviceId: deviceId, type: .disconnected, interrupted: interrupted, error: reason)
        let owner = self.owner
        return {
            if let failedConnect, let connectError = outcome.connect {
                failedConnect.reply.fail(connectError)
            }
            session?.close(operationError: outcome.operations, subscriptionError: outcome.subscriptions)
            for disconnect in disconnects {
                if let error = outcome.disconnects {
                    disconnect.fail(error)
                } else {
                    disconnect.succeed()
                }
            }
            guard session != nil else { return }
            onDisconnect?.fire(event)
            owner?.connectionEvent(event)
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        session?.didDiscoverServices(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        session?.didDiscoverCharacteristics(for: service, error: error)
    }

    /**
     * Handled only while the link is up (`upSession`): not before it came up or after it
     * went down, not while an operation timeout or disconnect() takes it down, and not
     * when CoreBluetooth already dropped it while its didDisconnectPeripheral still waits
     * on the queue. On a link going down the close is the only thing that ends its
     * subscriptions (with the close's error), and no ServicesChanged event follows its
     * Disconnected one.
     */
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let session = upSession else { return }
        session.servicesModified(invalidatedServices)
        owner?.connectionEvent(ConnectionEvent(deviceId: deviceId, type: .serviceschanged, interrupted: false, error: nil))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        session?.didUpdateValue(for: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        session?.didWriteValue(for: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        session?.readyToSendWriteWithoutResponse()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        session?.didUpdateNotificationState(for: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        session?.didReadRSSI(RSSI, error: error)
    }
}
