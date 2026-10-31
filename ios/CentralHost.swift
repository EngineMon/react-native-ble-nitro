import Foundation
import CoreBluetooth

/**
 * The owner of one CBCentralManager: its serial queue, the queue's marker, the central
 * (made on first need) and its delegate, which forwards CoreBluetooth's calls to the
 * manager core attached to it (BleCore, the tenant: HostTenancy). Every core runs on a
 * host; the facade picks it by restore identifier (`forManager`).
 *
 * Two kinds, one lifecycle model:
 * - Private host (no restore identifier): made for one core, which attaches in its first
 *   task. Closed when that core releases it at its teardown: the central's delegate is
 *   cleared and the central released, as a core's own central always was. With
 *   BLENitroLazyInit the central waits for the core's first need.
 * - Process host (a restore identifier): one per identifier for the life of the process
 *   (`processHosts`), never closed. Every manager made with the identifier runs on it;
 *   a core detaches at its teardown and the central stays. Two centrals with one restore
 *   identifier can never exist, since CoreBluetooth would hand the restored state to only
 *   one of them. A core attaching while another is still attached supersedes it
 *   (HostTenancy.attach, BleCore.supersede): the old one is torn down first, so a JS
 *   reload is deterministic whether the new manager is made before or after the old
 *   one's deinit.
 *
 * Why at launch (`launch`, BleNitroLaunch.h): when iOS relaunches the app for a Bluetooth
 * event (a peripheral it kept connected, or a connect it kept pending, came up), it hands
 * the restored peripherals (willRestoreState) to a central made with the same restore
 * identifier, which Apple says to make again in application(_:didFinishLaunching
 * WithOptions:) (Core Bluetooth Programming Guide, "Reinstantiate your central and
 * peripheral managers"). A central the JS manager makes when its module loads comes as
 * late as React Native starts, if it starts at all. The identifier comes from Info.plist
 * (`restoreIdentifierInfoKey`), so the launch needs no argument and the app configures it
 * once.
 *
 * The central's options. Every central gets the host's restore identifier, if it has one.
 * The launch's central also gets CBCentralManagerOptionShowPowerAlertKey false: a launch
 * may be a background one for a reason unrelated to Bluetooth (location, a push, a
 * background task), and CoreBluetooth's default would show its "turn on Bluetooth" alert
 * then, interrupting the user for nothing they did. A central made at a core's first need
 * keeps CoreBluetooth's defaults, as a manager's central always had (the app asked for
 * Bluetooth then). Both are made on the queue and only when the host has none
 * (`ensureCentral`, `launch`), so whichever comes first is the one central, with its
 * options, for the host's life; the other finds it and does nothing. Normally the launch
 * comes first: it runs before React Native starts.
 *
 * Edge cases, and where they are handled:
 * - First install (permission not determined), permission denied or restricted: `launch`
 *   makes nothing, since making a central asks for the permission and a launch must never
 *   prompt. The central is made at the first need of a core (right after it is created,
 *   or with lazy init at its first call or iosLazyInit()), which prompts exactly when a
 *   manager's central always did; denied or restricted, it reports unauthorized without
 *   a prompt. Granted mid-run: that central goes on; the next launch makes it at launch.
 * - Permission revoked while running: the central reports unauthorized (unless iOS
 *   terminates the app, as it may when a privacy permission is revoked), which ends the
 *   links as any state below poweredOn does (BleCore.bluetoothBecameUnavailable). The
 *   next launch makes no central.
 * - Bluetooth off at launch: the launch's central is made without the power alert (see
 *   above) and reports poweredOff; the core gets that state at its attach, and the app
 *   shows its own guidance.
 * - `launch` called twice, late, or off the main thread: the registry makes one host per
 *   identifier under a lock, and the central is made on the host's queue only when the
 *   host has none. Posted, never waited for: the launch must not block on a queue a core
 *   may be busy on. Called without the Info.plist key: reported (`reportAppMistake`),
 *   nothing made.
 * - A launch for another reason (location, push, background task) makes the central with
 *   no core attached, maybe for the whole process (React Native may not even start).
 *   Until a core attaches: the restored state is kept for it, and keeping it keeps the
 *   restored peripherals retained, so the connects the system kept pending for them stay
 *   pending; every other call is dropped (HostTenancy). A pending connect that completes
 *   meanwhile is seen at the attach: the core reads the peripheral's state when the
 *   restoration hands it over (BleCore.centralWillRestoreState).
 * - Bluetooth leaving poweredOn while no core is attached: the state reaches the next
 *   core at its attach. Below poweredOff the kept restored state is dropped, since its
 *   peripherals are invalid then (`centralManagerDidUpdateState`).
 * - Restored state before, at or after the attach: before (or while the attached core is
 *   being destroyed), kept and handed to the next core at its attach, ahead of the
 *   current state (CoreBluetooth's order); after, straight to the live core. Each
 *   restored peripheral gets a link there, reported connected only if it is connected
 *   then; connect() adopts a connected one, takes over a connecting one and connects a
 *   disconnected one again (PeripheralLink.connect). A restored scan runs, its results
 *   dropped until startScan or stopScan replaces it (BleScanner.restore). One window is
 *   left open: CoreBluetooth takes stopScan only while powered on, so a core that took a
 *   restored scan and ends before the central's first state update (milliseconds after
 *   it is made: a manager destroyed or superseded right after its creation) can't stop
 *   it; the OS scan then runs, results dropped, until a later core starts a scan, which
 *   replaces it.
 * - The "nothing restored" report (StateRestoration): CoreBluetooth calls no
 *   willRestoreState when it has nothing to restore, so a core reports an empty
 *   restoration at its first known state. A core attaching to a central whose state is
 *   known gets it replayed at the attach (`attach`), else the first update reaches it as
 *   it comes; so the first core and a superseding one each report once. The restored
 *   state goes to one core only: a superseding core reports an empty restoration, never
 *   its predecessor's list again.
 * - A pending connect (ConnectDeadline.never) of a superseded or destroyed core is
 *   cancelled at its teardown; a didConnect that raced the cancel reaches the next core,
 *   which has no link for it and ignores it (BleCore.centralDidConnect), and
 *   CoreBluetooth reports the cancelled connection down.
 * - JS reload, both orders, destroy() twice, dispose() then deinit, two managers alive
 *   with one identifier, a manager destroyed before its first task: HostTenancy and
 *   BleCore.supersede / BleCore.destroy.
 * - A manager without a restore identifier beside the process host: a private host,
 *   its own queue and central, independent of the process host's.
 * - iosLazyInit() on a process host: makes the central if the host has none yet,
 *   nothing if the launch made it. A core attaches (and supersedes) at creation whether
 *   or not lazy init is on, and gets a launch central's restored state then.
 * - A JS restore identifier other than Info.plist's: an app mistake, reported
 *   (`forManager`). The manager gets the process host of the identifier it asked for:
 *   the API's meaning stays, and the launch central (of Info.plist's identifier) gets
 *   no manager.
 *
 * Queue marker (`isOnQueue`): a synchronous getter called from code already on the queue
 * (a C++ callback calling back in) must run inline, where `queue.sync` would deadlock.
 * One key for every host, never freed, and a token object per host as its value: the
 * queue retains the token, so no later host's token can reuse the address of one still
 * set on a queue that outlived its host. On a process host every core of the queue sees
 * itself on it, so a callback of the live core calling a superseded core's getter gets
 * that core's empty value inline.
 *
 * Memory: the registry holds process hosts for good; a core holds its host strongly;
 * the host holds the tenant weakly and is the central's (weak) delegate, so a private
 * host goes away with its core and nothing forms a cycle. The kept restored state, one
 * dictionary at most, is released when a core takes it.
 *
 * Threading: `restoreIdentifier` and `queue` are immutable; everything else is confined
 * to `queue`, where CoreBluetooth delivers the delegate calls.
 */
final class CentralHost: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    /// The Info.plist key with the app's restore identifier: what `launch` makes the central with, and what a manager's identifier must match.
    private static let restoreIdentifierInfoKey = "BLENitroRestoreIdentifier"

    /// The label of every host's queue; a process host's adds its restore identifier, so crash logs and Instruments tell the two kinds apart.
    private static let queueLabel = "co.zyke.ble.nitro"
    /// What a host's queue carries under `queueKey` (see the class comment).
    private final class QueueToken {}

    private static let queueKey = DispatchSpecificKey<QueueToken>()
    /// The process hosts, one per restore identifier, for the life of the process.
    private static let processHosts = ProcessRegistry<CentralHost>()

    /// Nil: a private host. Set: the process host for this identifier, and every central it makes has it.
    let restoreIdentifier: String?
    /// The central's delegate queue, and the queue of every core on this host.
    let queue: DispatchQueue
    private let queueToken = QueueToken()
    private let tenancy = HostTenancy<BleCore, [String: Any]>()
    /// Made once, by `ensureCentral` or `launch`; a private host releases it when it closes.
    private var central: CBCentralManager?

    private init(restoreIdentifier: String?) {
        self.restoreIdentifier = restoreIdentifier
        queue = DispatchQueue(label: restoreIdentifier.map { "\(Self.queueLabel).\($0)" } ?? Self.queueLabel)
        super.init()
        queue.setSpecific(key: Self.queueKey, value: queueToken)
    }

    // MARK: - Hosts

    /**
     * The host of a manager made with `restoreIdentifier`: a new private host without
     * one, else the process host for it. An identifier other than Info.plist's is
     * reported (see the class comment).
     */
    static func forManager(restoreIdentifier: String?) -> CentralHost {
        guard let restoreIdentifier else {
            return CentralHost(restoreIdentifier: nil)
        }
        if let configured = configuredRestoreIdentifier, configured != restoreIdentifier {
            reportAppMistake("A manager was created with restore identifier \(restoreIdentifier), but Info.plist's \(restoreIdentifierInfoKey) is \(configured): the central made at launch never gets a manager, so what iOS restores into it never reaches the app. Use one identifier.")
        }
        return processHost(restoreIdentifier)
    }

    private static func processHost(_ restoreIdentifier: String) -> CentralHost {
        return processHosts.value(for: restoreIdentifier) { CentralHost(restoreIdentifier: restoreIdentifier) }
    }

    /// Info.plist's restore identifier; nil when the key is absent, not a string, or empty.
    private static var configuredRestoreIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: restoreIdentifierInfoKey) as? String,
              !identifier.isEmpty else { return nil }
        return identifier
    }

    /**
     * BleNitroDidFinishLaunching: makes the central of Info.plist's restore identifier,
     * only with Bluetooth permission granted already (making a central asks for it, and a
     * launch must never prompt), and without the power alert (see the class comment). Any
     * thread, any number of calls.
     */
    static func launch() {
        guard let identifier = configuredRestoreIdentifier else {
            reportAppMistake("BleNitroDidFinishLaunching was called without \(restoreIdentifierInfoKey) in Info.plist: no central is made at launch, and state restoration waits for the first manager")
            return
        }
        guard CBManager.authorization == .allowedAlways else { return }
        let host = processHost(identifier)
        host.queue.async { _ = host.ensureCentral(showsPowerAlert: false) }
    }

    // MARK: - For the cores (on the queue)

    /// Whether the caller runs on `queue` (see the class comment).
    var isOnQueue: Bool {
        return DispatchQueue.getSpecific(key: Self.queueKey) === queueToken
    }

    /**
     * `core`'s first task: it takes the central's calls from now on, after a core still
     * attached was superseded (HostTenancy.attach). It gets what a central of its own
     * would have given it so far, in CoreBluetooth's order: the restored state kept for
     * it, then the current state, unless that is still unknown (the first update then
     * reaches it as it comes). Its callbacks may destroy it inline, so each step is for a
     * core still live.
     */
    func attach(_ core: BleCore) {
        if let restored = tenancy.attach(core) {
            core.centralWillRestoreState(restored)
        }
        if tenancy.live === core, let central, central.state != .unknown {
            core.centralDidUpdateState(central)
        }
    }

    /// Whether `core` is attached: from its first task until its teardown, or until a newer core superseded it.
    func isAttached(_ core: BleCore) -> Bool {
        return tenancy.isAttached(core)
    }

    /// The central as `core` sees it: nil unless `core` is attached (see BleCore.central).
    func attachedCentral(of core: BleCore) -> CBCentralManager? {
        return tenancy.isAttached(core) ? central : nil
    }

    /// The central, made with CoreBluetooth's default options if the host has none yet (see the class comment for the launch's).
    func ensureCentral() -> CBCentralManager {
        return ensureCentral(showsPowerAlert: true)
    }

    /**
     * `core`'s teardown: it gets no more calls. A private host closes with its one core:
     * the delegate is cleared (no more central calls) and the central released, so a
     * manager made right after can use the same restore identifier, as when the core
     * owned its central. A process host keeps its central for the next core.
     */
    func release(_ core: BleCore) {
        tenancy.detach(core)
        guard restoreIdentifier == nil else { return }
        central?.delegate = nil
        central = nil
    }

    /// The one place a central is made: only when the host has none, so the first maker's options stay for the host's life.
    private func ensureCentral(showsPowerAlert: Bool) -> CBCentralManager {
        if let central {
            return central
        }
        var options: [String: Any] = [:]
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        if !showsPowerAlert {
            options[CBCentralManagerOptionShowPowerAlertKey] = false
        }
        let made = CBCentralManager(delegate: self, queue: queue, options: options.isEmpty ? nil : options)
        central = made
        return made
    }

    // MARK: - CBCentralManagerDelegate (on the queue)
    //
    // Requirement (NativeBleNitro.nitro.ts, section "After destroy()"): no new OS work starts
    // and no state changes once destroy() was called. Calls CoreBluetooth queued ahead of
    // the teardown would otherwise re-issue a pending connect (didDisconnectPeripheral),
    // bring a link up and announce it (didConnect), or run the calls waiting for a state
    // (centralManagerDidUpdateState). Every call therefore goes to the live tenant only
    // (HostTenancy.live), at this one boundary: from the destroy() call on, the teardown
    // owns the links, the scan and the waiting calls. With no live tenant a call is
    // dropped, except the restored state, which is kept for the next tenant.

    /**
     * Below poweredOff CoreBluetooth invalidates every peripheral the central handed out,
     * and ends their connects (BleCore.bluetoothBecameUnavailable): a restored state kept
     * for the next core names only dead objects then, which a core would link and wait on
     * forever, so it is dropped. The live core forgets its own.
     */
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state.rawValue < CBManagerState.poweredOff.rawValue {
            tenancy.dropKeptRestore()
        }
        tenancy.live?.centralDidUpdateState(central)
    }

    /// Always handled when a restore identifier is set (CoreBluetooth only calls it then).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        tenancy.restore(dict)?.centralWillRestoreState(dict)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        tenancy.live?.centralDidDiscover(peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        tenancy.live?.centralDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        tenancy.live?.centralDidFailToConnect(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        tenancy.live?.centralDidDisconnect(peripheral, error: error)
    }
}

/**
 * An app mistake the library survives but the developer must fix: logged always, and an
 * assertion failure in debug builds (Swift's assertionFailure stops only unoptimized
 * builds, so release builds go on with the logged behavior instead of crashing).
 */
private func reportAppMistake(_ message: String) {
    bleLog(message)
    assertionFailure("[BleNitro] " + message)
}

/**
 * BleNitroDidFinishLaunching's Swift side: BleNitroLaunch.mm implements the C function
 * with it, since the app target includes only plain C headers of this pod.
 */
@objc(BleNitroLaunch)
public final class BleNitroLaunch: NSObject {
    @objc public static func didFinishLaunching() {
        CentralHost.launch()
    }
}
