import Foundation
import CoreBluetooth

/**
 * The service and characteristic UUID forms the native API accepts
 * (NativeBleNitro.nitro.ts, section "UUIDs"), the same on Android (GattUuid.kt) and in the JS
 * wrapper's strict parser, in any letter case:
 * - 16-bit, 4 hex digits ("180D"), and 32-bit, 8 hex digits ("0000180D"), both on the
 *   Bluetooth Base UUID (Bluetooth Core Specification Vol 3 Part B §2.5.1);
 * - 128-bit as 32 hex digits without dashes;
 * - 128-bit in the canonical 8-4-4-4-12 form (36 characters).
 * Everything else is InvalidIdentifiers. A C++ caller calls the native API directly, so
 * the rule is enforced here, not only in JS: the same input must name the same UUID, or
 * fail, on both platforms.
 *
 * Every UUID a caller passes goes through `parse`, also for this reason:
 * CBUUID(string:) raises an Objective-C exception (a crash) on a malformed string.
 */
enum GattUuid {
    /// The UUID `text` names, or nil when it is none of the accepted forms.
    static func parse(_ text: String) -> CBUUID? {
        let characters = Array(text.utf8)
        switch characters.count {
        case 4, 8:
            guard characters.allSatisfy(isHexDigit) else { return nil }
            return CBUUID(string: text)
        case 32:
            guard characters.allSatisfy(isHexDigit) else { return nil }
            // CBUUID(string:) takes a 128-bit UUID only in the canonical form: a dash goes
            // before the 9th, 13th, 17th and 21st digit.
            var canonical = ""
            for (offset, character) in text.enumerated() {
                if offset == 8 || offset == 12 || offset == 16 || offset == 20 {
                    canonical.append("-")
                }
                canonical.append(character)
            }
            return CBUUID(string: canonical)
        case 36:
            for (offset, character) in characters.enumerated() {
                let valid = dashOffsets.contains(offset) ? character == UInt8(ascii: "-") : isHexDigit(character)
                guard valid else { return nil }
            }
            return CBUUID(string: text)
        default:
            return nil
        }
    }

    /// Where the canonical form has its dashes: 8-4-4-4-12.
    private static let dashOffsets: Set<Int> = [8, 13, 18, 23]

    private static func isHexDigit(_ character: UInt8) -> Bool {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"):
            return true
        default:
            return false
        }
    }
}

extension CBUUID {
    /**
     * The form every reported UUID takes (NativeBleNitro.nitro.ts, section "UUIDs"): full 128-bit,
     * lowercase, as Android's UUID.toString() gives it. CoreBluetooth reports 16- and
     * 32-bit UUIDs in their short form; they expand on the Bluetooth Base UUID
     * (Bluetooth Core Specification Vol 3 Part B §2.5.1).
     */
    var fullUUIDString: String {
        let uuid = uuidString.lowercased()
        switch uuid.count {
        case 4: return "0000\(uuid)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(uuid)-0000-1000-8000-00805f9b34fb"
        default: return uuid
        }
    }
}
