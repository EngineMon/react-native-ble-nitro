import Foundation
import CoreBluetooth

/**
 * The central's delegate: forwards CoreBluetooth's calls, which arrive on the manager's
 * queue, to BleCore. A separate NSObject holding the core weakly, since BleCore is no
 * NSObject and CBCentralManager.delegate is weak (BleCore keeps this object alive).
 *
 * Requirement (NativeBleNitro.nitro.ts, section "After destroy()"): no new OS work starts and no
 * state changes once destroy() was called. Calls CoreBluetooth queued ahead of the
 * teardown would otherwise re-issue a pending connect (didDisconnectPeripheral), bring a
 * link up and announce it (didConnect), or run the calls waiting for a state
 * (centralManagerDidUpdateState). Every call is therefore dropped here, at one boundary,
 * from the destroy() call on: the teardown owns the links, the scan and the waiting calls.
 */
final class BleCentralManagerDelegate: NSObject, CBCentralManagerDelegate {
    private weak var core: BleCore?

    init(core: BleCore) {
        self.core = core
        super.init()
    }

    /// The core, while destroy() hasn't been called.
    private var liveCore: BleCore? {
        guard let core, !core.isDestroying else { return nil }
        return core
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        liveCore?.centralDidUpdateState(central)
    }

    /// Always handled when a restore identifier is set (CoreBluetooth only calls it then).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        liveCore?.centralWillRestoreState(dict)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        liveCore?.centralDidDiscover(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        liveCore?.centralDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        liveCore?.centralDidFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        liveCore?.centralDidDisconnect(peripheral, error: error)
    }
}
