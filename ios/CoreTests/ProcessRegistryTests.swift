import Foundation
import XCTest
@testable import BleNitroCore

/// Unit tests for `ProcessRegistry`: one host per restore identifier, whoever asks first.
final class ProcessRegistryTests: XCTestCase {
    private final class Host {}

    func testOneValuePerKeyMadeAtItsFirstLookup() {
        let registry = ProcessRegistry<Host>()
        var made: [String] = []

        let first = registry.value(for: "a") { made.append("a"); return Host() }
        let again = registry.value(for: "a") { made.append("a"); return Host() }
        let other = registry.value(for: "b") { made.append("b"); return Host() }

        XCTAssertTrue(first === again)
        XCTAssertFalse(first === other)
        XCTAssertEqual(made, ["a", "b"])
    }

    func testConcurrentFirstLookupsOfAKeyShareOneValue() {
        let registry = ProcessRegistry<Host>()
        let lock = NSLock()
        var seen = Set<ObjectIdentifier>()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let host = registry.value(for: "id") { Host() }
            lock.lock()
            seen.insert(ObjectIdentifier(host))
            lock.unlock()
        }

        XCTAssertEqual(seen.count, 1)
    }
}
