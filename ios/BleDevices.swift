import Foundation
import CoreBluetooth
import NitroModules

/**
 * Which connected devices getConnectedDevices reports. The meaning is the same on both
 * platforms (BleDevices.kt): `services` empty is `any`, otherwise `anyOf` the UUIDs of it
 * that parse. An entry that doesn't parse names no service, so it matches nothing:
 * `anyOf([])` reports no device. A synchronous getter never throws on its input
 * (NativeBleNitro.nitro.ts, getConnectedDevices).
 */
enum ServiceFilter {
    /// Every link of this manager that is up.
    case any
    /// This manager's links whose discovered services include one of these, and the
    /// peripherals the system holds connected that offer one of them.
    case anyOf([CBUUID])

    init(services: [String]) {
        self = services.isEmpty ? .any : .anyOf(services.compactMap(GattUuid.parse))
    }

    /// Whether `peripheral`'s discovered services pass the filter.
    func admits(_ peripheral: CBPeripheral) -> Bool {
        switch self {
        case .any:
            return true
        case .anyOf(let uuids):
            return peripheral.services?.contains { uuids.contains($0.uuid) } ?? false
        }
    }
}

extension BLEDevice {
    /**
     * The rssi of a device known without an advertisement (restored, or connected). The
     * spec makes rssi a number: 127 is HCI's "RSSI not available" value (Bluetooth Core
     * Specification Vol 4 Part E §7.7.65.2), which CoreBluetooth also reports when it has
     * none. Android reports the same. A scan's rssiThreshold never lets it pass
     * (BleScanner.didDiscover).
     */
    static var rssiUnavailable: Double { return 127 }

    /// A scan result. isConnected: whether this manager's link to the device is up.
    static func advertised(
        _ peripheral: CBPeripheral,
        _ advertisementData: [String: Any],
        rssi: Double,
        isConnected: Bool
    ) -> BLEDevice {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return BLEDevice(
            id: peripheral.identifier.uuidString,
            // "" when the device has no name, as on Android.
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "",
            rssi: rssi,
            manufacturerData: manufacturerData(advertisementData),
            serviceData: serviceData(advertisementData),
            serviceUUIDs: serviceUUIDs.map { $0.fullUUIDString },
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? true,
            isConnected: isConnected
        )
    }

    /**
     * A device known without an advertisement (restored, or connected): no RSSI (see
     * rssiUnavailable), advertisement data or advertised connectability. isConnectable is
     * true since it was connected to. isConnected is the caller's: whether this manager's
     * link is up (getConnectedDevices), or whether iOS restored it connected (restoration).
     */
    static func known(_ peripheral: CBPeripheral, isConnected: Bool) -> BLEDevice {
        return BLEDevice(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            rssi: rssiUnavailable,
            manufacturerData: ManufacturerData(companyIdentifiers: []),
            serviceData: ServiceData(services: []),
            serviceUUIDs: peripheral.services?.map { $0.uuid.fullUUIDString } ?? [],
            isConnectable: true,
            isConnected: isConnected
        )
    }

    /// One entry: `id` the company identifier (little endian, as a decimal string), `data` the bytes after it.
    private static func manufacturerData(_ advertisementData: [String: Any]) -> ManufacturerData {
        guard let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, raw.count >= 2 else {
            return ManufacturerData(companyIdentifiers: [])
        }
        let companyId = UInt16(raw[raw.startIndex]) | UInt16(raw[raw.startIndex + 1]) << 8
        let entry = ManufacturerDataEntry(id: String(companyId), data: ArrayBuffer.copying(raw.dropFirst(2)))
        return ManufacturerData(companyIdentifiers: [entry])
    }

    private static func serviceData(_ advertisementData: [String: Any]) -> ServiceData {
        let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return ServiceData(services: raw.map { ServiceDataEntry(uuid: $0.key.fullUUIDString, data: ArrayBuffer.copying($0.value)) })
    }
}
