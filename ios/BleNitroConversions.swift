import Foundation
import CoreBluetooth
import NitroModules

// Conversions between CoreBluetooth's types and the spec's. Errors are built in
// BleErrors.swift, devices in BleDevices.swift, UUIDs parsed in GattUuid.swift.

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
}

extension ArrayBuffer {
    /// A new owning buffer with a copy of `data`: the one copy a value takes on its way out.
    static func copying(_ data: Data) -> ArrayBuffer {
        let buffer = ArrayBuffer.allocate(size: data.count)
        data.copyBytes(to: buffer.data, count: data.count)
        return buffer
    }
}

extension CharacteristicProperties {
    /**
     * The properties `characteristic` declares (Bluetooth Core Specification Vol 3 Part G
     * §3.3.1.1). CBCharacteristicProperties uses the declaration's bits, so the mapping is
     * one to one.
     */
    init(declaredBy characteristic: CBCharacteristic) {
        let properties = characteristic.properties
        self.init(
            read: properties.contains(.read),
            write: properties.contains(.write),
            writeWithoutResponse: properties.contains(.writeWithoutResponse),
            notify: properties.contains(.notify),
            indicate: properties.contains(.indicate)
        )
    }
}
