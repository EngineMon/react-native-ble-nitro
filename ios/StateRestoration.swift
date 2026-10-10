import Foundation
import CoreBluetooth
import NitroModules

/**
 * State restoration's report (iOS only): the peripherals CoreBluetooth restored, reported
 * once per manager to the restore callback. On the manager's queue only.
 *
 * Requirements (NativeBleNitro.nitro.ts, setRestoreStateCallback):
 * - The report is made once. A report made before a callback was registered waits for it,
 *   since restoration happens when the central is created, often before JS registered.
 * - With a restore identifier and nothing restored, the callback gets an empty list, once,
 *   so a caller waiting for the report learns there is none (as ble-plx emits a null
 *   restored state on a first run, BleModule.onRestoreState).
 */
final class StateRestoration {
    private enum Report {
        case notReported
        /// Reported before a callback was registered.
        case waitingForCallback([BLEDevice])
        case delivered
    }

    private var report = Report.notReported
    private var callback: Once<[BLEDevice]>?

    init(callback: Once<[BLEDevice]>?) {
        self.callback = callback
    }

    /// The restore callback; a report made already reaches it at once.
    func setCallback(_ callback: Once<[BLEDevice]>) {
        self.callback = callback
        deliver()
    }

    /// The restored devices; ignored after the first report.
    func report(_ devices: [BLEDevice]) {
        guard case .notReported = report else { return }
        report = .waitingForCallback(devices)
        deliver()
    }

    /// destroy(): the callback is released and never fires.
    func discard() {
        callback = nil
    }

    private func deliver() {
        guard case .waitingForCallback(let devices) = report, let callback else { return }
        report = .delivered
        self.callback = nil
        callback.fire(devices)
    }

    /// The peripherals in willRestoreState's dictionary.
    static func peripherals(_ state: [String: Any]) -> [CBPeripheral] {
        return state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    }

    /// Whether the dictionary restores a running scan.
    static func restoresScan(_ state: [String: Any]) -> Bool {
        return state[CBCentralManagerRestoredStateScanServicesKey] != nil
    }
}
