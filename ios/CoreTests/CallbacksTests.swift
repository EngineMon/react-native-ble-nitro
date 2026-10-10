import Foundation
import XCTest
@testable import BleNitroCore

/// Unit tests for the one-shot wrappers `Reply` and `Once`. (Swift can't catch what a
/// C++ callback throws, so the Android mirror's throw-isolation tests have no
/// counterpart here; see Callbacks.swift.)
final class CallbacksTests: XCTestCase {
    /// Counts deliveries from many threads.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private let timedOut = TestError("OPERATIONTIMEDOUT", "timed out")

    func testReplyDeliversOnlyTheFirstCompletion() {
        var delivered: [String] = []
        let reply = Reply<Int, TestError> { error, value in
            delivered.append("\(error?.code ?? "nil") \(value.map(String.init) ?? "nil")")
        }

        reply.fail(timedOut)
        reply.succeed(1)
        reply.fail(timedOut)

        XCTAssertEqual(delivered, ["OPERATIONTIMEDOUT nil"])
    }

    func testReplyIsCompletedOnceEvenWhenThreadsRace() {
        let deliveries = Counter()
        let reply = Reply<Int, TestError> { _, _ in deliveries.increment() }

        DispatchQueue.concurrentPerform(iterations: 8) { n in
            reply.succeed(n)
        }

        XCTAssertEqual(deliveries.value, 1)
    }

    func testReplyReleasesItsCallbackWhenItCompletes() {
        final class Captured {}
        var captured: Captured? = Captured()
        weak var released = captured
        let reply = Reply<Void, TestError> { [captured] _, _ in
            _ = captured
        }
        captured = nil
        XCTAssertNotNil(released)

        reply.succeed()

        // What the callback held (a JS function, a C++ closure) doesn't outlive the
        // completion, even though the operation holding the Reply may.
        XCTAssertNil(released)
    }

    func testOnceFiresOnlyTheFirstTime() {
        var fired: [Int] = []
        let once = Once<Int> { fired.append($0) }

        once.fire(1)
        once.fire(2)

        XCTAssertEqual(fired, [1])
    }

    func testOnceReleasesItsCallbackWhenItFires() {
        final class Captured {}
        var captured: Captured? = Captured()
        weak var released = captured
        let once = Once<Int> { [captured] _ in
            _ = captured
        }
        captured = nil
        XCTAssertNotNil(released)

        once.fire(1)

        XCTAssertNil(released)
    }
}
