import Foundation
import CoreBluetooth
import NitroModules

/**
 * One scan's callback, as the facade wrapped it (CallbackGate), in its three roles:
 * - `onResult`: every reported advertisement while the scan runs. A listener.
 * - `startFailure`: the scan couldn't start (invalid filter, Bluetooth not on, destroyed).
 *   A completion: fires also after destroy(), with BluetoothManagerDestroyed.
 * - `ended`: the running scan ended without stopScan (Bluetooth left the powered-on
 *   state). An event: silent after destroy().
 * The two failure roles are separate because they follow different after-destroy rules
 * (NativeBleNitro.nitro.ts, section "After destroy()": a start that hadn't reached the OS reports
 * BluetoothManagerDestroyed, a running scan ends silently). Only a start that hasn't
 * reached the OS fires `startFailure`, only a running scan fires `ended`, so at most one
 * of them fires, and a scan that is stopped or replaced gets nothing more.
 */
final class ScanCallbacks {
    let onResult: Listener<BLEDevice>
    let startFailure: ScanStartFailure
    let ended: Once<BleError>

    init(onResult: Listener<BLEDevice>, startFailure: ScanStartFailure, ended: Once<BleError>) {
        self.onResult = onResult
        self.startFailure = startFailure
        self.ended = ended
    }
}

/**
 * The scan of one manager (one at a time, NativeBleNitro.nitro.ts, startScan), and the
 * peripherals scans discovered. On the manager's queue only. BleCore decides when a scan
 * may start (Bluetooth on, not destroyed); this class holds what runs and talks to the
 * central about it. Android's counterpart is BleScanner.kt.
 */
final class BleScanner {
    /// Whose scan runs.
    private enum Owner {
        /// The system restored a scan (state restoration): it runs, but its results go
        /// nowhere until startScan replaces it or stopScan ends it.
        case restored
        case caller(ScanCallbacks)
    }

    private final class Running {
        let owner: Owner
        let rssiThreshold: Double?
        let allowDuplicates: Bool
        /// With an rssiThreshold and without allowDuplicates: the devices reported already.
        var reported: Set<String> = []

        init(owner: Owner, rssiThreshold: Double?, allowDuplicates: Bool) {
            self.owner = owner
            self.rssiThreshold = rssiThreshold
            self.allowDuplicates = allowDuplicates
        }
    }

    private var running: Running?

    /**
     * stopScan ended a scan while the central's state was still `.unknown`: a restored
     * scan, stopped before the first state update. CoreBluetooth accepts stopScan only
     * while powered on (it logs API misuse otherwise and ignores it), so the OS scan is
     * stopped at the first powered-on state instead (`centralPoweredOn`), unless a new
     * scan replaced it by then.
     */
    private var stopWhenPoweredOn = false

    /**
     * Peripherals seen by scans, kept so they can be connected: CoreBluetooth needs the
     * app to retain a peripheral it uses. Bounded: every scan start drops the ones that
     * aren't connected (see `start`).
     */
    private var discovered: [String: CBPeripheral] = [:]

    var isScanning: Bool {
        return running != nil
    }

    /**
     * Starts a scan, replacing the running one, whose callback gets nothing more. The
     * caller checked that Bluetooth is on.
     *
     * rssiThreshold: CoreBluetooth coalesces a device's advertisements into one discovery
     * unless AllowDuplicates is on (CBCentralManagerScanOptionAllowDuplicatesKey), so a
     * device first heard weaker than the threshold would never be reported once it comes
     * closer. With a threshold the scan therefore always runs with duplicates, and without
     * allowDuplicates each device is reported once, the first time it passes. iOS ignores
     * AllowDuplicates for apps in the background (CoreBluetooth background execution
     * modes): there a device first heard too weak is not reported again.
     */
    func start(
        on central: CBCentralManager,
        services: [CBUUID],
        rssiThreshold: Double?,
        allowDuplicates: Bool,
        callbacks: ScanCallbacks
    ) {
        // Keeps `discovered` bounded: what the last scan found and nobody connected is
        // dropped (a connect falls back to retrievePeripherals for it anyway).
        discovered = discovered.filter { $0.value.state != .disconnected }
        running = Running(owner: .caller(callbacks), rssiThreshold: rssiThreshold, allowDuplicates: allowDuplicates)
        stopWhenPoweredOn = false
        central.scanForPeripherals(
            withServices: services.isEmpty ? nil : services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates || rssiThreshold != nil]
        )
    }

    /// Stops the scan; returns whether one was running. Its callback gets nothing more.
    func stop(on central: CBCentralManager?) -> Bool {
        guard running != nil else { return false }
        running = nil
        if let central {
            if central.state == .poweredOn {
                central.stopScan()
            } else if central.state == .unknown {
                stopWhenPoweredOn = true
            }
        }
        return true
    }

    /// The system restored a running scan (state restoration).
    func restore() {
        running = Running(owner: .restored, rssiThreshold: nil, allowDuplicates: false)
    }

    /// The central reached the powered-on state.
    func centralPoweredOn(_ central: CBCentralManager) {
        if stopWhenPoweredOn {
            stopWhenPoweredOn = false
            central.stopScan()
        }
    }

    /**
     * Bluetooth left the powered-on state, which ends the OS scan without a call. Forgets
     * the scan and returns its `ended` event (nil for no scan, or a restored one) for the
     * caller to fire once every other state change of the transition is done (collect,
     * then fire).
     */
    func abandon() -> Once<BleError>? {
        let abandoned = running
        running = nil
        stopWhenPoweredOn = false
        guard let abandoned, case .caller(let callbacks) = abandoned.owner else { return nil }
        return callbacks.ended
    }

    /// A peripheral a scan discovered, for connect().
    func discoveredPeripheral(_ deviceId: String) -> CBPeripheral? {
        return discovered[deviceId]
    }

    /// Releases the peripherals scans discovered (CoreBluetooth invalidated them, or the manager is destroyed).
    func forgetPeripherals() {
        discovered.removeAll()
    }

    /**
     * An advertisement. Reports it to the caller's scan unless the rssiThreshold drops it:
     * RSSI 127 is HCI's "not available" (Bluetooth Core Specification Vol 4 Part E
     * §7.7.65.2), not a strong signal, so it never passes a threshold. `isConnected` tells
     * whether this manager's link to a device is up (BLEDevice.isConnected); asked only
     * for a reported device.
     */
    func didDiscover(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber,
        isConnected: (String) -> Bool
    ) {
        guard let running, case .caller(let callbacks) = running.owner else { return }
        let deviceId = peripheral.identifier.uuidString
        let rssi = rssi.doubleValue
        if let threshold = running.rssiThreshold {
            guard rssi != BLEDevice.rssiUnavailable, rssi >= threshold else { return }
            if !running.allowDuplicates && !running.reported.insert(deviceId).inserted {
                return
            }
        }
        discovered[deviceId] = peripheral
        callbacks.onResult.emit(BLEDevice.advertised(peripheral, advertisementData, rssi: rssi, isConnected: isConnected(deviceId)))
    }
}
