import Foundation
import XCTest
@testable import BleNitroCore

/// Unit tests for `IdSource`. It is process-wide, so the tests assert relations between
/// ids, never absolute values.
final class IdSourceTests: XCTestCase {
    /// The ids the threads drew, collected under a lock.
    private final class Drawn: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int64] = []

        func add(_ more: [Int64]) {
            lock.lock()
            ids.append(contentsOf: more)
            lock.unlock()
        }

        var all: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    func testIdsArePositiveAndIncreasing() {
        let first = IdSource.next()
        let second = IdSource.next()

        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThan(second, first)
    }

    func testIdsAreUniqueAcrossThreads() {
        let perThread = 1_000
        let threads = 8
        let drawn = Drawn()

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            drawn.add((0 ..< perThread).map { _ in IdSource.next() })
        }

        XCTAssertEqual(Set(drawn.all).count, perThread * threads)
    }
}
