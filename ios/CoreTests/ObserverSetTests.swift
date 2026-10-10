import XCTest
@testable import BleNitroCore

/// Unit tests for `ObserverSet`.
final class ObserverSetTests: XCTestCase {
    private let observers = ObserverSet<Int>()
    private let log = EventLog()

    private func observe(_ id: Int64, onValue: @escaping (Int) -> Void = { _ in }) {
        observers.add(id: id, Listener { [log] value in
            log.add("\(id) got \(value)")
            onValue(value)
        })
    }

    func testEmitsToEveryObserverInRegistrationOrder() {
        observe(2)
        observe(1)
        observe(3)

        observers.emit(7)

        XCTAssertEqual(log.entries, ["2 got 7", "1 got 7", "3 got 7"])
    }

    func testRemovedObserverHearsNothingMore() {
        observe(1)
        observe(2)

        XCTAssertTrue(observers.remove(id: 1))
        XCTAssertFalse(observers.remove(id: 1))
        observers.emit(7)

        XCTAssertEqual(log.entries, ["2 got 7"])
    }

    func testObserverRemovedDuringEmitIsSkipped() {
        observe(1) { [observers] _ in observers.remove(id: 2) }
        observe(2)
        observe(3)

        observers.emit(7)

        XCTAssertEqual(log.entries, ["1 got 7", "3 got 7"])
    }

    func testObserverAddedDuringEmitWaitsForTheNextEmit() {
        observe(1) { [unowned self] value in
            if value == 7 {
                self.observe(2)
            }
        }

        observers.emit(7)
        observers.emit(8)

        XCTAssertEqual(log.entries, ["1 got 7", "1 got 8", "2 got 8"])
    }

    func testClearDuringEmitSilencesEveryObserver() {
        observe(1) { [observers] _ in observers.clear() }
        observe(2)

        observers.emit(7)
        observers.emit(8)

        XCTAssertEqual(log.entries, ["1 got 7"])
    }
}
