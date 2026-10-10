import XCTest
@testable import BleNitroCore

/**
 * Unit tests for `GattRules`. Property bits are written out as the Core spec's
 * characteristic properties (Vol 3 Part G §3.3.1.1), not taken from `GattRules`, so a
 * wrong constant there fails here. (CCCD mode selection is Android-only: CoreBluetooth
 * picks notify or indicate itself.)
 */
final class GattRulesTests: XCTestCase {
    private let read: UInt = 0x02
    private let writeWithoutResponse: UInt = 0x04
    private let write: UInt = 0x08
    private let notify: UInt = 0x10
    private let indicate: UInt = 0x20

    private func violation(_ access: GattRules.Access, _ properties: UInt, maxWithoutResponse: Int = 20) -> GattRules.Violation? {
        return GattRules.violation(access, properties: properties, maxWithoutResponse: maxWithoutResponse)
    }

    func testEachAccessRequiresItsOwnPropertyBit() {
        let writeRequest = GattRules.Access.write(length: 1, withResponse: true)
        let writeCommand = GattRules.Access.write(length: 1, withResponse: false)
        XCTAssertNil(violation(.read, read))
        XCTAssertNil(violation(writeRequest, write))
        XCTAssertNil(violation(writeCommand, writeWithoutResponse))

        XCTAssertEqual(violation(.read, write | notify), .notPermitted(.read))
        XCTAssertEqual(violation(writeRequest, writeWithoutResponse), .notPermitted(writeRequest))
        XCTAssertEqual(violation(writeCommand, write), .notPermitted(writeCommand))
    }

    func testNotifyAcceptsNotifyOrIndicate() {
        XCTAssertNil(violation(.notify, notify))
        XCTAssertNil(violation(.notify, indicate))
        XCTAssertEqual(violation(.notify, read | write), .notPermitted(.notify))
    }

    func testPermissionIsCheckedBeforeLength() {
        let tooLong = GattRules.Access.write(length: 600, withResponse: true)

        XCTAssertEqual(violation(tooLong, writeWithoutResponse), .notPermitted(tooLong))
    }

    func testWriteWithResponseIsLimitedTo512Bytes() {
        XCTAssertNil(violation(.write(length: 512, withResponse: true), write, maxWithoutResponse: 20))
        XCTAssertEqual(
            violation(.write(length: 513, withResponse: true), write, maxWithoutResponse: 514),
            .tooLong(length: 513, limit: 512)
        )
    }

    func testWriteWithoutResponseIsLimitedToOnePdu() {
        // ATT_MTU 512: 509 bytes of value fit one Write Command.
        XCTAssertNil(violation(.write(length: 509, withResponse: false), writeWithoutResponse, maxWithoutResponse: 509))
        XCTAssertEqual(
            violation(.write(length: 510, withResponse: false), writeWithoutResponse, maxWithoutResponse: 509),
            .tooLong(length: 510, limit: 509)
        )
    }

    func testWriteWithoutResponseIsLimitedTo512BytesEvenWhenOnePduHoldsMore() {
        // ATT_MTU 517: one PDU would hold 514 bytes, an attribute value only 512.
        XCTAssertNil(violation(.write(length: 512, withResponse: false), writeWithoutResponse, maxWithoutResponse: 514))
        XCTAssertEqual(
            violation(.write(length: 513, withResponse: false), writeWithoutResponse, maxWithoutResponse: 514),
            .tooLong(length: 513, limit: 512)
        )
    }

    func testAbsentOrInfiniteTimeoutHasNoDeadline() {
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: nil), .never)
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: .infinity), .never)
    }

    func testConnectDeadlineIsRoundedUpToWholeMillisecondsAndCapped() {
        let max = Int(Int32.max)
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: 1_000), .after(ms: 1_000))
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: 0.25), .after(ms: 1))
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: 1_000.5), .after(ms: 1_001))
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: Double(Int32.max)), .after(ms: max))
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: Double(Int32.max) + 0.5), .after(ms: max))
        XCTAssertEqual(GattRules.connectDeadline(timeoutMs: 1e300), .after(ms: max))
    }

    func testConnectDeadlineRejectsNaNZeroNegativeAndMinusInfinity() {
        for ms in [Double.nan, 0, -0.0, -1, -Double.infinity] {
            XCTAssertNil(GattRules.connectDeadline(timeoutMs: ms), "timeoutMs \(ms)")
        }
    }

    func testMtuRequestMustBeAnIntegerFrom23To517() {
        XCTAssertEqual(GattRules.validMtuRequest(mtu: 23), 23)
        XCTAssertEqual(GattRules.validMtuRequest(mtu: 517), 517)
        for mtu in [22, 518, 185.5, Double.nan, Double.infinity] {
            XCTAssertNil(GattRules.validMtuRequest(mtu: mtu), "mtu \(mtu)")
        }
    }
}
