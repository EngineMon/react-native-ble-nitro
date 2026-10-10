import XCTest
@testable import BleNitroCore

/**
 * Unit tests for `GattOperationQueue`, on a manual clock. Its owner does what the glue
 * does from `onStall`: marks the link closing, then closes the queue with the
 * link-down error.
 */
final class GattOperationQueueTests: XCTestCase {
    private final class TestOperation: GattOperation {
        let name: String
        let timeoutMs: Int
        private let log: EventLog
        private let startError: TestError?
        private let settles: Bool
        /// Runs inside `start`, before it returns.
        var onStart: (() -> Void)?
        /// Runs inside `fail`, after it logged.
        var onFail: (() -> Void)?
        /// The causes it was failed with.
        private(set) var causes: [FailCause] = []

        init(_ name: String, log: EventLog, startError: TestError?, timeoutMs: Int, settlesOnTimeout: Bool) {
            self.name = name
            self.log = log
            self.startError = startError
            self.timeoutMs = timeoutMs
            self.settles = settlesOnTimeout
        }

        var description: String {
            return name
        }

        func start() -> TestError? {
            log.add("start \(name)")
            onStart?()
            return startError
        }

        func fail(_ error: TestError, cause: FailCause) {
            causes.append(cause)
            log.add("fail \(name) \(error.code)")
            onFail?()
        }

        func settleOnTimeout() -> Bool {
            guard settles else { return false }
            log.add("settle \(name)")
            return true
        }
    }

    private static let timeout = 30_000

    private let timer = FakeTimer()
    private let log = EventLog()
    private let lost = TestError("DEVICEDISCONNECTED", "link lost")
    /// Set by the owner when it starts taking the link down.
    private var ownerClosing = false
    /// Runs in the owner's `onStall` before it closes the queue.
    private var whileStalling: (() -> Void)?
    private lazy var queue: GattOperationQueue<TestOperation> = GattOperationQueue(
        timer: timer,
        timeoutError: { TestError("OPERATIONTIMEDOUT", $0) },
        onStall: { [unowned self] operation in
            self.ownerClosing = true
            self.log.add("stall \(operation.name)")
            self.whileStalling?()
            self.queue.close(self.lost)
        }
    )

    private func operation(
        _ name: String,
        startError: TestError? = nil,
        timeoutMs: Int = timeout,
        settlesOnTimeout: Bool = false
    ) -> TestOperation {
        return TestOperation(name, log: log, startError: startError, timeoutMs: timeoutMs, settlesOnTimeout: settlesOnTimeout)
    }

    @discardableResult
    private func complete(_ operation: TestOperation) -> Bool {
        return queue.complete(operation) { log.add("done \(operation.name)") }
    }

    func testRunsOneOperationAtATimeInEnqueueOrder() {
        let a = operation("a")
        let b = operation("b")
        let c = operation("c")
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(c)
        XCTAssertEqual(log.entries, ["start a"])

        complete(a)
        complete(b)

        XCTAssertEqual(log.entries, ["start a", "done a", "start b", "done b", "start c"])
        XCTAssertTrue(queue.current === c)
    }

    func testStartFailureFailsTheOperationAndStartsTheNext() {
        let a = operation("a", startError: TestError("OPERATIONSTARTFAILED", "refused"))
        let b = operation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        XCTAssertEqual(log.entries, ["start a", "fail a OPERATIONSTARTFAILED", "start b"])
        XCTAssertTrue(queue.current === b)
    }

    func testResultIsDeliveredBeforeTheNextOperationStartsOrFails() {
        let a = operation("a")
        let b = operation("b", startError: TestError("OPERATIONSTARTFAILED", "refused"))
        queue.enqueue(a)
        queue.enqueue(b)

        complete(a)

        XCTAssertEqual(log.entries, ["start a", "done a", "start b", "fail b OPERATIONSTARTFAILED"])
        XCTAssertNil(queue.current)
    }

    func testOperationEnqueuedByACompletionRunsAfterItAndAfterTheOnesAlreadyWaiting() {
        let a = operation("a")
        let b = operation("b")
        let c = operation("c")
        queue.enqueue(a)
        queue.enqueue(b)

        queue.complete(a) {
            queue.enqueue(c)
            log.add("done a")
        }
        complete(b)

        XCTAssertEqual(log.entries, ["start a", "done a", "start b", "done b", "start c"])
    }

    func testOperationThatCompletesInsideItsOwnStartLetsTheNextStartAfterward() {
        // Its start also returns an error after completing: dropped, a is never failed.
        let a = operation("a", startError: TestError("OPERATIONSTARTFAILED", "moot"))
        a.onStart = { [unowned self, unowned a] in
            self.queue.complete(a) { self.log.add("done a") }
            self.log.add("a returns from start")
        }
        let b = operation("b")
        let first = operation("first")
        queue.enqueue(first)
        queue.enqueue(a)
        queue.enqueue(b)

        complete(first)

        XCTAssertEqual(log.entries, ["start first", "done first", "start a", "done a", "a returns from start", "start b"])
        XCTAssertTrue(queue.current === b)
    }

    func testCompletingAnOperationThatIsNotInFlightIsIgnored() {
        let a = operation("a")
        let b = operation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        XCTAssertFalse(complete(b))

        XCTAssertEqual(log.entries, ["start a"])
        XCTAssertTrue(queue.current === a)
    }

    func testCompletionCancelsTheTimeout() {
        let a = operation("a")
        queue.enqueue(a)
        complete(a)

        timer.advance(Self.timeout * 2)

        XCTAssertEqual(log.entries, ["start a", "done a"])
    }

    func testTimeoutStallsTheQueueThenFailsTheOperation() {
        let a = operation("a")
        let b = operation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(Self.timeout - 1)
        XCTAssertEqual(log.entries, ["start a"])
        timer.advance(1)
        XCTAssertEqual(log.entries, ["start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED"])

        // Nothing runs on a stalled link, and the late answer is ignored.
        timer.advance(Self.timeout * 2)
        XCTAssertFalse(complete(a))
        XCTAssertNil(queue.current)
        XCTAssertEqual(log.entries, ["start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED"])
    }

    func testOperationsEnqueuedAfterAStallWaitForTheClose() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))
        // Enqueued while the owner handles the stall, before it closes: nothing starts it.
        whileStalling = { [unowned self] in self.queue.enqueue(self.operation("c")) }

        timer.advance(Self.timeout)

        XCTAssertEqual(
            log.entries,
            ["start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"]
        )
    }

    func testTimeoutStallsTheOwnerBeforeTheOperationFails() {
        let a = operation("a")
        var seenByTheFailure: [String] = []
        a.onFail = { [unowned self, unowned a] in
            seenByTheFailure.append("owner closing \(self.ownerClosing), in flight \(self.queue.current === a)")
            // A late answer (or one the failure's callback provokes) can't complete it again.
            seenByTheFailure.append("completed again \(self.queue.complete(a) {})")
        }
        queue.enqueue(a)

        timer.advance(Self.timeout)

        XCTAssertEqual(log.entries, ["start a", "stall a", "fail a OPERATIONTIMEDOUT"])
        XCTAssertEqual(seenByTheFailure, ["owner closing true, in flight false", "completed again false"])
    }

    func testCloseFromOnStallFailsTheTimedOutOperationFirstThenTheWaitingOnes() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))

        timer.advance(Self.timeout)
        queue.enqueue(operation("c"))
        timer.advance(Self.timeout * 2)

        XCTAssertEqual(
            log.entries,
            ["start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"]
        )
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isClosed)
    }

    func testStalledOperationFailsEvenWhenTheOwnerDoesNotClose() {
        let negligent = GattOperationQueue<TestOperation>(
            timer: timer,
            timeoutError: { TestError("OPERATIONTIMEDOUT", $0) },
            onStall: { [log] operation in log.add("stall \(operation.name)") }
        )
        negligent.enqueue(operation("a"))
        negligent.enqueue(operation("b"))

        timer.advance(Self.timeout)
        negligent.enqueue(operation("c"))

        // The queue closes itself with the timeout error: nothing waits forever.
        XCTAssertEqual(
            log.entries,
            ["start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b OPERATIONTIMEDOUT", "fail c OPERATIONTIMEDOUT"]
        )
        XCTAssertTrue(negligent.isClosed)
    }

    func testCloseFromAnOperationsFailFailsTheWaitingOnesAndStartsNothing() {
        // As the glue's close funnel does when an operation's failure takes the link down.
        let a = operation("a", startError: TestError("OPERATIONSTARTFAILED", "refused"))
        a.onFail = { [unowned self] in self.queue.close(self.lost) }
        let first = operation("first")
        queue.enqueue(first)
        queue.enqueue(a)
        queue.enqueue(operation("b"))
        queue.enqueue(operation("c"))

        complete(first)
        timer.advance(Self.timeout * 2)

        XCTAssertEqual(
            log.entries,
            ["start first", "done first", "start a", "fail a OPERATIONSTARTFAILED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"]
        )
        XCTAssertNil(queue.current)
    }

    func testCloseFromInsideADeliverFailsTheWaitingOnesAndStartsNothing() {
        let a = operation("a")
        queue.enqueue(a)
        queue.enqueue(operation("b"))

        queue.complete(a) {
            log.add("done a")
            queue.close(lost)
        }
        timer.advance(Self.timeout * 2)

        XCTAssertEqual(log.entries, ["start a", "done a", "fail b DEVICEDISCONNECTED"])
        XCTAssertNil(queue.current)
    }

    func testEachOperationHasItsOwnTimeout() {
        let a = operation("a", timeoutMs: 5_000)
        let b = operation("b", timeoutMs: 1_000)
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(4_000)
        complete(a)
        timer.advance(999)
        XCTAssertEqual(log.entries, ["start a", "done a", "start b"])
        timer.advance(1)

        XCTAssertEqual(log.entries, ["start a", "done a", "start b", "stall b", "fail b OPERATIONTIMEDOUT"])
    }

    func testOperationThatSettlesOnTimeoutEndsItselfAndTheNextStarts() {
        let a = operation("a", timeoutMs: 3_000, settlesOnTimeout: true)
        let b = operation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(3_000)

        XCTAssertEqual(log.entries, ["start a", "settle a", "start b"])
        XCTAssertTrue(queue.current === b)
        XCTAssertFalse(complete(a))
    }

    func testCloseFailsTheRunningAndEveryWaitingOperationInOrder() {
        queue.enqueue(operation("a"))
        queue.enqueue(operation("b"))
        queue.enqueue(operation("c"))

        queue.close(lost)
        timer.advance(Self.timeout * 2)

        XCTAssertEqual(log.entries, ["start a", "fail a DEVICEDISCONNECTED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"])
        XCTAssertNil(queue.current)
    }

    func testClosedQueueFailsEveryLaterOperationAtOnceWithTheFirstCloseError() {
        XCTAssertFalse(queue.isClosed)
        queue.close(lost)
        queue.close(TestError("BLUETOOTHMANAGERDESTROYED"))

        queue.enqueue(operation("a"))

        XCTAssertEqual(log.entries, ["fail a DEVICEDISCONNECTED"])
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.isClosed)
    }

    func testEachFailureReportsItsCause() {
        let refused = operation("refused", startError: TestError("OPERATIONSTARTFAILED", "refused"))
        let timedOut = operation("timedOut")
        let waiting = operation("waiting")
        let late = operation("late")
        queue.enqueue(refused)
        queue.enqueue(timedOut)
        queue.enqueue(waiting)

        timer.advance(Self.timeout)
        queue.enqueue(late)

        XCTAssertEqual(refused.causes, [.startRefused])
        XCTAssertEqual(timedOut.causes, [.timedOut])
        XCTAssertEqual(waiting.causes, [.queueClosed])
        XCTAssertEqual(late.causes, [.queueClosed])
    }

    func testLateCompletionAfterCloseIsIgnored() {
        let a = operation("a")
        queue.enqueue(a)
        queue.close(lost)

        XCTAssertFalse(complete(a))

        XCTAssertEqual(log.entries, ["start a", "fail a DEVICEDISCONNECTED"])
    }
}
