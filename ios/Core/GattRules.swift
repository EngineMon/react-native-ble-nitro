/**
 * The ATT/GATT limits and input rules every link applies, as pure functions of their
 * inputs. The glue checks them when an operation starts and maps a violation to a
 * `BleError` (see `Violation`).
 */
enum GattRules {
    /// ATT_MTU of an LE link until an MTU exchange raises it (Core Vol 3 Part G §5.2.1).
    static let defaultAttMtu = 23
    /// Octets of a Write Request or Write Command PDU that aren't value: opcode (1) and
    /// attribute handle (2). A write carries at most ATT_MTU − 3 octets in one PDU.
    static let attWriteHeader = 3
    /// The longest attribute value: "The maximum length of an attribute value shall be
    /// 512 octets" (Core Vol 3 Part F §3.2.9). Also the most a long (prepared) write
    /// with response can carry.
    static let maxAttributeLength = 512
    /// The largest ATT_MTU worth requesting: a 512-octet value plus the 5-octet header of
    /// a Prepare Write Request (opcode, handle, offset). Android's upper bound for
    /// `BluetoothGatt.requestMtu`.
    static let maxAttMtu = 517
    /// An ATT transaction not answered within 30 s has timed out, and no further ATT
    /// PDUs may be sent on that bearer (Core Vol 3 Part F §3.3.3). The per-operation
    /// timeout of every ATT procedure.
    static let attTransactionTimeoutMs = 30_000

    // Characteristic properties bits, as the Characteristic Declaration encodes them
    // (Core Vol 3 Part G §3.3.1.1). CBCharacteristicProperties and Android's
    // BluetoothGattCharacteristic.PROPERTY_* use the same bits.
    static let propertyRead: UInt = 0x02
    static let propertyWriteWithoutResponse: UInt = 0x04
    static let propertyWrite: UInt = 0x08
    static let propertyNotify: UInt = 0x10
    static let propertyIndicate: UInt = 0x20

    /**
     * What an operation does with a characteristic. A write carries its length and type,
     * so the one check (`violation`) can't be asked about a write without its length.
     */
    enum Access: Equatable {
        case read
        /// Subscribe: notifications or indications.
        case notify
        /// A write of `length` octets, as a Write Request (`withResponse`) or a Write Command.
        case write(length: Int, withResponse: Bool)
    }

    /**
     * Why a characteristic refuses an operation. The glue maps it to a `BleError`
     * naming the characteristic, without a native status: `notPermitted(.read)` →
     * CharacteristicReadFailed (402); `notPermitted(.write)` and `tooLong` →
     * CharacteristicWriteFailed (401), the message giving both numbers for `tooLong`;
     * `notPermitted(.notify)` → CharacteristicNotifyChangeFailed (403).
     */
    enum Violation: Equatable {
        /// The characteristic doesn't declare the property the access needs.
        case notPermitted(Access)
        /// The value is longer than the write type can carry.
        case tooLong(length: Int, limit: Int)
    }

    /**
     * When a connect attempt gives up. Only valid deadlines exist: the facade turns an
     * unusable `ConnectOptions.timeoutMs` into an error (`connectDeadline` returns nil),
     * so nothing below it can receive one.
     */
    enum ConnectDeadline: Equatable {
        /// No deadline: the attempt runs until it succeeds, fails or is cancelled. (Not
        /// `none`, which reads as `Optional.none` where a `ConnectDeadline?` is expected.)
        case never
        /// Fail the attempt after `ms` milliseconds (at least 1).
        case after(ms: Int)
    }

    /**
     * Why a characteristic with `properties` (the Core-spec bitmask) refuses `access`,
     * or nil when it allows it. `maxWithoutResponse` is the most one Write Command
     * carries on this link (ATT_MTU − 3 on Android,
     * `maximumWriteValueLength(for: .withoutResponse)` on iOS).
     *
     * Permission first, strict: each access requires its own bit, checked before
     * anything goes on air. The OSes check only part of this, differently: Android's
     * `writeCharacteristic` accepts either write bit for both write types, so a request
     * the peripheral doesn't support goes out and fails with an ATT error, or a Write
     * Command is silently ignored; CoreBluetooth drops a write without response to a
     * characteristic that doesn't declare it with only a console warning, so the caller
     * would see success while nothing was sent. One strict check gives the same clear
     * error on both platforms. `notify` accepts notify or indicate: the CCCD can enable
     * either, and CoreBluetooth and the Android glue pick the one the characteristic
     * supports.
     *
     * Then the length of a write:
     * - With response: at most 512 octets (Core Vol 3 Part F §3.2.9). Longer values
     *   can't be written at all; Android 6 to 14 truncate them silently and Android 15
     *   throws.
     * - Without response: at most `min(maxWithoutResponse, 512)`. A Write Command
     *   carries only ATT_MTU − 3 octets and has no long-write procedure (Core Vol 3
     *   Part G §4.9.1); Android truncates a longer value silently, so the peripheral
     *   would get a different value than the caller sent. The 512 cap still applies
     *   when ATT_MTU − 3 exceeds it (an MTU of 517 allows 514).
     */
    static func violation(_ access: Access, properties: UInt, maxWithoutResponse: Int) -> Violation? {
        switch access {
        case .read:
            return properties & propertyRead == 0 ? .notPermitted(access) : nil
        case .notify:
            return properties & (propertyNotify | propertyIndicate) == 0 ? .notPermitted(access) : nil
        case .write(let length, let withResponse):
            let required = withResponse ? propertyWrite : propertyWriteWithoutResponse
            if properties & required == 0 {
                return .notPermitted(access)
            }
            let limit = withResponse ? maxAttributeLength : min(maxWithoutResponse, maxAttributeLength)
            return length > limit ? .tooLong(length: length, limit: limit) : nil
        }
    }

    /**
     * The connect deadline `ConnectOptions.timeoutMs` asks for, or nil when it isn't a
     * usable timeout (the connect then fails with OperationStartFailed).
     *
     * - nil or +∞: `never`.
     * - Finite and > 0: `after`, rounded up to whole milliseconds (so 0.5 still means
     *   a timeout, not an immediate failure) and capped at Int32.max ms (24.8 days):
     *   converting an arbitrary Double to an integer traps in Swift when it is out of
     *   range, and the Android mirror caps it the same way because a delay near
     *   Long.MAX overflows its Handler's uptime arithmetic into "run now".
     * - NaN, ≤ 0 or −∞: nil. None of them describes a time to wait.
     */
    static func connectDeadline(timeoutMs: Double?) -> ConnectDeadline? {
        guard let timeoutMs else { return .never }
        if timeoutMs.isNaN || timeoutMs <= 0 { return nil }
        if timeoutMs == .infinity { return .never }
        let capped = min(timeoutMs.rounded(.up), Double(Int32.max))
        return .after(ms: Int(capped))
    }

    /**
     * `mtu` as a valid MTU request: an integer from 23 (`defaultAttMtu`, the least an LE
     * link may use) to 517 (`maxAttMtu`), else nil (the request fails with
     * DeviceMTUChangeFailed, 206). Returning the converted value means the caller can't
     * use an unchecked conversion of the Double.
     */
    static func validMtuRequest(mtu: Double) -> Int? {
        guard mtu.rounded(.towardZero) == mtu, mtu >= Double(defaultAttMtu), mtu <= Double(maxAttMtu) else {
            return nil
        }
        return Int(mtu)
    }
}
