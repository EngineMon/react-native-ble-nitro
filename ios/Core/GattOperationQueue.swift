/// Why `GattOperationQueue` failed an operation (`GattOperation.fail`).
enum FailCause: Equatable {
    /// Its `start` returned an error: the OS refused it, or the glue's checks did.
    case startRefused
    /// Its answer didn't come within `timeoutMs`; the queue stalled on it.
    case timedOut
    /// The queue closed (link down, disconnect, manager destroyed) while it was running
    /// or waiting, or it was enqueued after the close. Its own request never failed.
    case queueClosed
}

/**
 * One GATT procedure waiting in, or running at the head of, a `GattOperationQueue`.
 * A class: the queue tells operations apart by identity.
 */
protocol GattOperation: AnyObject {
    /// The error the operation fails with (`BleError` in the glue).
    associatedtype Failure

    /// What the operation does, for error messages, e.g. "Read of characteristic X of service Y on <device>".
    var description: String { get }

    /// How long the operation may wait for its answer once started, in milliseconds.
    /// `GattRules.attTransactionTimeoutMs` for an ATT procedure.
    var timeoutMs: Int { get }

    /**
     * Issues the operation to the OS. Returns nil when the OS accepted it (the operation
     * then waits for `GattOperationQueue.complete` or its timeout), or the error to fail
     * it with (`FailCause.startRefused`).
     *
     * The operation may also settle itself from inside `start` (`complete(self)` for a
     * request the OS answers locally); the next operation then starts after `start`
     * returns, and an error `start` returns after that is dropped.
     */
    func start() -> Failure?

    /**
     * Reports the operation's failure to its caller. Called at most once, and never
     * after it completed.
     *
     * `cause` says which path failed it, so an operation whose outcome depends on it
     * reads it here instead of the owner keeping a copy of the queue's state. A CCCD
     * unsubscribe, for one, succeeds on `.queueClosed` (the subscription ended with the
     * link anyway) and fails on its own refusal or timeout.
     */
    func fail(_ error: Failure, cause: FailCause)

    /**
     * Called when `timeoutMs` passed without an answer. The operation is already out of
     * flight (a late `complete` for it returns false).
     *
     * Return false, reporting nothing, for an ATT procedure: its timeout means the link
     * is unusable (see `GattOperationQueue`), so the queue stalls and fails it with
     * OperationTimedOut (`FailCause.timedOut`). Return true only after reporting the
     * operation's own result, for a request whose answer the OS may legitimately never
     * send while its outcome is known without it (Android 14+ ignores an MTU request
     * after the connection's first exchange, possibly without a callback); the queue
     * then moves on. Report the result directly, not through `complete`.
     *
     * No default implementation, unlike the Android mirror's interface default: in
     * Swift a protocol-extension default becomes the witness of a class that doesn't
     * implement the method itself, and a subclass's own `settleOnTimeout` would then
     * never be called through the protocol. Every operation type states its policy.
     */
    func settleOnTimeout() -> Bool
}

/// Runs delayed tasks on the queue's executor (the manager's serial queue in the app, a fake clock in tests).
protocol OperationTimer {
    /// Runs `task` on the executor after `delayMs` milliseconds, unless it is cancelled first.
    func schedule(_ task: @escaping () -> Void, delayMs: Int) -> any ScheduledTask
}

/// A task an `OperationTimer` scheduled.
protocol ScheduledTask: AnyObject {
    /// Keeps the task from running. Called on the executor, so the task either already ran or never will.
    func cancel()
}

/**
 * The GATT operations of one link, run one at a time in FIFO order.
 *
 * Requirements:
 * - One outstanding procedure per link: an ATT client sends no other request on a
 *   bearer until the current one is answered (Core Vol 3 Part F §3.3.2), Android's
 *   BluetoothGatt refuses a second request while the first awaits its callback, and
 *   CoreBluetooth answers two requests of the same kind on the same characteristic
 *   through the same delegate callback, which can't be told apart. So exactly one
 *   operation is in flight and the others wait in enqueue order.
 * - An operation completes only through the callback that answers it (`complete`),
 *   identity-checked: an answer for an operation that is no longer in flight (it timed
 *   out, failed or was closed) returns false and is dropped.
 * - Every operation has a timeout (`GattOperation.timeoutMs`). An ATT transaction not
 *   completed within 30 s means no further ATT PDUs may be sent on that bearer
 *   (Core Vol 3 Part F §3.3.3), and Android keeps its internal busy flag set until the
 *   late callback, so every following operation would fail with BUSY. On a timeout the
 *   queue stalls (starts nothing else) and calls the owner's `onStall`, which takes the
 *   link down and closes the queue. Since no operation of the link ever runs again, a
 *   late OS answer can't complete a later operation of the same kind.
 *   `GattOperation.settleOnTimeout` is the one exception, for requests the OS may never
 *   answer.
 * - The owner's state changes before the timeout's first callback fires (collect, then
 *   fire): `onStall` runs BEFORE the timed-out operation fails, so a C++ completion that
 *   calls a synchronous getter inline when it gets OperationTimedOut already sees the
 *   link going down, not a link that still looks up. The operation is out of flight
 *   during `onStall` (`current` is nil, a late `complete` returns false), and the queue
 *   keeps it aside with its OperationTimedOut error. The reported order: the owner's
 *   `close` from `onStall` fails the timed-out operation first, with OperationTimedOut,
 *   then the waiting ones with the close error (and the owner ends its subscriptions
 *   after that).
 * - A stalled queue never stays open: if `onStall` returns without closing it (an
 *   owner bug, logged), the queue closes itself with the OperationTimedOut error, so
 *   the waiting operations and every later one fail instead of waiting forever.
 * - `close(error)` fails the running and every waiting operation, and every later
 *   `enqueue` fails its operation at once with the same error: a queue belongs to one
 *   link and is never reopened.
 * - Every failure carries its `FailCause`, the queue's own knowledge of why, so the
 *   owner keeps no copy of the queue's state to interpret a failure.
 * - Results are reported in operation order, and no operation starts while the queue
 *   calls out (an operation's `start`, `fail` or `settleOnTimeout`, a `deliver`, or
 *   `onStall`): an operation enqueued from a callout starts after the callout returns,
 *   so one operation's start failure can't overtake the result being delivered.
 * - Exactly once: every operation either completes (`deliver` runs once) or fails once,
 *   whichever path ends it (answer, start error, timeout, close, `close` called from
 *   inside `onStall`, a `deliver` or an operation's own `fail`). Swift closures here
 *   can't throw and a throwing C++ callback terminates the app (see `Reply`), so no
 *   callout can unwind through the queue and leave it half-updated (the Android mirror
 *   needs try/finally for that).
 *
 * Not thread-safe and not Sendable: confined to the manager's serial queue, which also
 * runs the timer's tasks.
 */
final class GattOperationQueue<Operation: GattOperation> {
    typealias Failure = Operation.Failure

    private enum State {
        case open
        /// An operation timed out: nothing starts any more; the queue closes before the
        /// timeout's handling returns.
        case stalled
        /// Every operation fails with the error.
        case closed(Failure)
    }

    private let timer: any OperationTimer
    private let timeoutError: (String) -> Failure
    private let onStall: (Operation) -> Void

    private var state = State.open
    private var waiting: [Operation] = []
    private var running: Operation?
    /// The running operation's timeout.
    private var timeout: (any ScheduledTask)?
    /// The operation that timed out and its OperationTimedOut error, from the timeout
    /// until `close` fails it (from `onStall`, or the queue's own close after it).
    private var stalled: (operation: Operation, error: Failure)?
    /// How many callouts are running (they nest: an operation may complete itself from
    /// its own `start`). No operation starts while it is above 0.
    private var callouts = 0

    /**
     * - Parameters:
     *   - timeoutError: makes the OperationTimedOut error from a message the queue
     *     formats ("<description> timed out after <timeoutMs> ms").
     *   - onStall: called with the operation that timed out, BEFORE it fails with
     *     OperationTimedOut. The owner marks the link closing, takes it down and closes
     *     the queue (which fails that operation first). The owner holds the queue, so the
     *     closure must not capture the owner strongly.
     */
    init(timer: any OperationTimer, timeoutError: @escaping (String) -> Failure, onStall: @escaping (Operation) -> Void) {
        self.timer = timer
        self.timeoutError = timeoutError
        self.onStall = onStall
    }

    /// The operation awaiting its answer, if any.
    var current: Operation? {
        return running
    }

    /// Whether the queue closed: every operation enqueued from now on fails at once.
    var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    /// Queues `operation`; it starts when every operation enqueued before it finished. Fails it at once when the queue is closed.
    func enqueue(_ operation: Operation) {
        if case .closed(let error) = state {
            callout { operation.fail(error, cause: .queueClosed) }
            return
        }
        waiting.append(operation)
        startNext()
    }

    /**
     * Completes `operation` if it is the one in flight: `deliver` reports its result,
     * then the next operation starts. Returns false, without calling `deliver`, when
     * `operation` is not in flight (it timed out, failed or the queue closed).
     */
    @discardableResult
    func complete(_ operation: Operation, deliver: () -> Void) -> Bool {
        guard running === operation else { return false }
        cancelTimeout()
        running = nil
        callout(deliver)
        startNext()
        return true
    }

    /**
     * Fails every operation, in queue order, and every operation enqueued later: the
     * timed-out one first with its OperationTimedOut error (`.timedOut`, so its caller
     * learns why), then the running and the waiting ones with `error` (`.queueClosed`).
     * Idempotent: the first error stays (a stalled link closes its queue when it stalls
     * and again when the OS reports it down). Re-entrant: an `onStall`, a `deliver` or an
     * operation's `fail` may call it; every operation still fails exactly once and none
     * starts.
     */
    func close(_ error: Failure) {
        if isClosed { return }
        state = .closed(error)
        cancelTimeout()
        var failed: [(operation: Operation, error: Failure, cause: FailCause)] = []
        if let stalled {
            failed.append((stalled.operation, stalled.error, .timedOut))
        }
        if let running {
            failed.append((running, error, .queueClosed))
        }
        failed += waiting.map { ($0, error, .queueClosed) }
        stalled = nil
        running = nil
        waiting.removeAll()
        for (operation, failure, cause) in failed {
            callout { operation.fail(failure, cause: cause) }
        }
    }

    private func startNext() {
        while callouts == 0, running == nil, isOpen, !waiting.isEmpty {
            let operation = waiting.removeFirst()
            running = operation
            scheduleTimeout(for: operation)
            guard let error = callout({ operation.start() }) else { continue }
            // Settled from inside start() (it completed itself, or a close failed it):
            // its outcome is already reported, the error is moot.
            guard running === operation else { continue }
            cancelTimeout()
            running = nil
            callout { operation.fail(error, cause: .startRefused) }
        }
    }

    private var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    private func timedOut(_ operation: Operation) {
        // The timer's cancel can't race the task (both run on the executor); the identity
        // check is what keeps a timeout from ever touching a later operation.
        guard running === operation else { return }
        timeout = nil
        running = nil
        if callout({ operation.settleOnTimeout() }) {
            startNext()
            return
        }
        state = .stalled
        let error = timeoutError("\(operation.description) timed out after \(operation.timeoutMs) ms")
        stalled = (operation, error)
        callout { onStall(operation) }
        if !isClosed {
            bleLog("\(operation.description) timed out and its owner left the queue open; closing it")
            close(error)
        }
    }

    private func scheduleTimeout(for operation: Operation) {
        timeout = timer.schedule({ [weak self, weak operation] in
            guard let self, let operation else { return }
            self.timedOut(operation)
        }, delayMs: operation.timeoutMs)
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func callout<T>(_ body: () -> T) -> T {
        callouts += 1
        defer { callouts -= 1 }
        return body()
    }
}
