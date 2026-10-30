import Foundation
import CoreBluetooth

/**
 * The central's delegate: forwards CoreBluetooth's calls, which arrive on the manager's
 * queue, to the BleCore attached to it. A separate NSObject holding the core weakly,
 * since BleCore is no NSObject and CBCentralManager.delegate is weak (whoever made the
 * central keeps this object alive: the core for a central of its own, SharedCentral for
 * the process's).
 *
 * Requirement (NativeBleNitro.nitro.ts, section "After destroy()"): no new OS work starts and no
 * state changes once destroy() was called. Calls CoreBluetooth queued ahead of the
 * teardown would otherwise re-issue a pending connect (didDisconnectPeripheral), bring a
 * link up and announce it (didConnect), or run the calls waiting for a state
 * (centralManagerDidUpdateState). Every call is therefore dropped here, at one boundary,
 * from the destroy() call on: the teardown owns the links, the scan and the waiting calls.
 *
 * Attaching (on the queue only): a core's own central has its core from the start. The
 * process's central (SharedCentral) exists before any core and outlives each: a core
 * attaches when it starts using it and detaches in its teardown. A core attaching gets
 * the start a central of its own would give it (`attach`):
 * - willRestoreState's dictionary, when it came while no live core was attached:
 *   CoreBluetooth calls it once, right after the central is made at launch, and the
 *   restored peripherals are what a relaunch is for. Only the first core gets it.
 * - The current state as an update of its own, once the central knows it (its empty
 *   restoration report, the calls waiting for a known state, its observers). Until then
 *   the first update reaches it as it comes.
 * Everything else CoreBluetooth reports while no live core is attached is about a
 * peripheral or scan of no core, and is dropped: a core reads a peripheral's state from
 * the peripheral when it takes it on.
 */
final class BleCentralManagerDelegate: NSObject, CBCentralManagerDelegate {
    private weak var core: BleCore?
    /// willRestoreState's dictionary, received while no live core was attached.
    private var missedRestore: [String: Any]?

    /// `core` nil: the process's central, which cores attach to later.
    init(core: BleCore? = nil) {
        self.core = core
        super.init()
    }

    /// The core, while destroy() hasn't been called.
    private var liveCore: BleCore? {
        guard let core, !core.isDestroying else { return nil }
        return core
    }

    /**
     * `core` gets `central`'s calls from now on, first its start (see the class comment),
     * in CoreBluetooth's order: the restored state, then the state update.
     */
    func attach(_ core: BleCore, central: CBCentralManager) {
        self.core = core
        if let restored = missedRestore {
            missedRestore = nil
            core.centralWillRestoreState(restored)
        }
        if central.state != .unknown {
            core.centralDidUpdateState(central)
        }
    }

    /// `core` gets no more calls (its teardown); a restore that comes until the next core attaches is kept for it.
    func detach(_ core: BleCore) {
        if self.core === core {
            self.core = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        liveCore?.centralDidUpdateState(central)
    }

    /// Always handled when a restore identifier is set (CoreBluetooth only calls it then).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let core = liveCore else {
            missedRestore = dict
            return
        }
        core.centralWillRestoreState(dict)
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
