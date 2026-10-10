import Foundation
import CoreBluetooth
import NitroModules

// Conversions between CoreBluetooth's types and the spec's.

extension BleError {
    /// An error this module detected itself; there is no platform status.
    init(_ code: BleErrorCode, _ message: String) {
        self.init(code: code, message: message, nativeStatus: nil)
    }

    /**
     * An operation that CoreBluetooth failed. As in ble-plx (MultiPlatformBleAdapter's
     * `Error.bleError(errorCode:)`), `code` names the operation that failed and the
     * platform error adds the detail: `nativeStatus` is its CBError or CBATTError code
     * (the two domains' numbers overlap; the message names the domain). It is absent
     * when CoreBluetooth gave no error, or one from another domain.
     */
    init(_ code: BleErrorCode, _ message: String, cause: Error?) {
        guard let cause = cause else {
            self.init(code, message)
            return
        }
        let error = cause as NSError
        let isCoreBluetooth = error.domain == CBErrorDomain || error.domain == CBATTErrorDomain
        self.init(
            code: code,
            message: "\(message): \(error.domain) \(error.code) (\(error.localizedDescription))",
            nativeStatus: isCoreBluetooth ? Double(error.code) : nil
        )
    }
}

extension CBManagerState {
    var bleState: BLEState {
        switch self {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredoff
        case .poweredOn: return .poweredon
        @unknown default: return .unknown
        }
    }

    /**
     * Why a request that needs Bluetooth on can't run in this state; nil when it is on.
     * The codes are ble-plx's (RxBluetoothKit's `BluetoothError(state:)`).
     */
    var unavailableError: BleError? {
        switch self {
        case .poweredOn: return nil
        case .poweredOff: return BleError(.bluetoothpoweredoff, "Bluetooth is turned off")
        case .unauthorized: return BleError(.bluetoothunauthorized, "Bluetooth use is not authorized")
        case .unsupported: return BleError(.bluetoothunsupported, "Bluetooth LE is not supported")
        case .resetting: return BleError(.bluetoothresetting, "Bluetooth is resetting")
        case .unknown: return BleError(.bluetoothinunknownstate, "Bluetooth state is not known yet")
        @unknown default: return BleError(.bluetoothinunknownstate, "Bluetooth is in unknown state \(rawValue)")
        }
    }
}

extension CBUUID {
    /**
     * Parses a 16-bit, 32-bit or 128-bit UUID string; nil for anything else. Every UUID
     * a caller passes goes through here: CBUUID(string:) raises an Objective-C exception
     * (a crash) on a malformed one.
     */
    static func parse(_ string: String) -> CBUUID? {
        let isShortForm = (string.count == 4 || string.count == 8) && string.allSatisfy { $0.isASCII && $0.isHexDigit }
        guard isShortForm || UUID(uuidString: string) != nil else { return nil }
        return CBUUID(string: string)
    }

    /**
     * The full lowercase 128-bit form, as Android's UUID.toString() and ble-plx's
     * fullUUIDString give it: 16- and 32-bit UUIDs expand on the Bluetooth base UUID.
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

extension ArrayBuffer {
    /// A new owning buffer with a copy of `data`: the one copy a value takes on its way out.
    static func copying(_ data: Data) -> ArrayBuffer {
        let buffer = ArrayBuffer.allocate(size: data.count)
        data.copyBytes(to: buffer.data, count: data.count)
        return buffer
    }
}
