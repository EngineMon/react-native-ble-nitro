import Foundation
import CoreBluetooth

/**
 * The process's central manager with a restore identifier, made by the app at launch
 * (BleNitroDidFinishLaunching, BleNitroLaunch.h), before any JS runs, and kept for the
 * life of the process.
 *
 * Why at launch: when iOS relaunches the app for a Bluetooth event (a peripheral it kept
 * connected or a connect it kept pending came up), it hands the restored peripherals
 * (willRestoreState) to a central made with the same restore identifier, and the app
 * must make that central in application(_:didFinishLaunchingWithOptions:) (Apple, Core
 * Bluetooth Programming Guide, "Reinstantiate your central and peripheral managers").
 * A central the JS manager makes when its module loads comes as late as React Native
 * starts; this one doesn't depend on it.
 *
 * Who uses it: the first manager created with the same restore identifier claims it
 * (BleNitroBleManager, which BleNitroBleManagerFactory.create makes) and builds its
 * BleCore on it instead of making a central of its own: the core runs on `queue`, the
 * central's delegate queue, and gets the central's calls through `delegate`, including
 * the ones it needs that came before it attached (BleCentralManagerDelegate). One
 * manager at a time: another one made while it is claimed makes a central of its own,
 * as it would without a launch central.
 *
 * A JS reload ends the manager (its deinit destroys its core) but not this central:
 * the core's teardown cancels the core's own connections and detaches it, and the
 * manager of the new runtime claims it again. The claim is released right after the
 * teardown is posted to `queue` (BleCore.destroy), so every task of the next core runs
 * after that teardown, on the same serial queue, and never meets its links.
 *
 * Made only with Bluetooth permission already granted (CBManager.authorization is
 * allowedAlways): making a central asks for it, and a launch, maybe in the background,
 * must never prompt. Without it the manager makes its own central as before, when the
 * app asks for Bluetooth.
 */
final class SharedCentral: @unchecked Sendable {
    let restoreIdentifier: String
    /// The central's delegate queue, and the queue of every core built on it.
    let queue: DispatchQueue
    /// Present only on `queue`, for every core on it (BleCore.queueKey).
    let queueKey = DispatchSpecificKey<Bool>()
    let central: CBCentralManager
    /// The central's delegate (CBCentralManager.delegate is weak, so this keeps it).
    let delegate: BleCentralManagerDelegate

    /// Guards `launched` and `claimed`.
    private static let lock = NSLock()
    private static var launched: SharedCentral?
    /// A manager's core runs on it.
    private var claimed = false

    private init(restoreIdentifier: String) {
        self.restoreIdentifier = restoreIdentifier
        queue = DispatchQueue(label: BleCore.queueLabel)
        queue.setSpecific(key: queueKey, value: true)
        delegate = BleCentralManagerDelegate()
        // The options a core makes its own central with (BleCore.ensureCentral).
        central = CBCentralManager(
            delegate: delegate,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        )
    }

    /// BleNitroDidFinishLaunching: makes the launch central, once per process, when Bluetooth permission is granted.
    static func launch(restoreIdentifier: String) {
        guard CBManager.authorization == .allowedAlways else { return }
        lock.lock()
        defer { lock.unlock() }
        if launched == nil {
            launched = SharedCentral(restoreIdentifier: restoreIdentifier)
        }
    }

    /**
     * The launch central for a new manager with `restoreIdentifier`, now its own until
     * `release()`; nil when there is none, it is claimed, or the identifiers differ. A
     * claimed one, or another identifier, is an app mistake (two centrals would then
     * share the process, and iOS restores into the launch one only), so it is logged.
     */
    static func claim(restoreIdentifier: String?) -> SharedCentral? {
        lock.lock()
        defer { lock.unlock() }
        guard let launched, let restoreIdentifier else { return nil }
        guard restoreIdentifier == launched.restoreIdentifier else {
            bleLog("The app made its launch central with restore identifier \(launched.restoreIdentifier), not \(restoreIdentifier): this manager makes its own central, and iOS restores state into the launch one")
            return nil
        }
        guard !launched.claimed else {
            bleLog("The launch central is another manager's: this manager makes its own central with the same restore identifier")
            return nil
        }
        launched.claimed = true
        return launched
    }

    /// The claiming core's destroy(): the next manager may claim it.
    func release() {
        Self.lock.lock()
        claimed = false
        Self.lock.unlock()
    }
}

/**
 * BleNitroDidFinishLaunching's Swift side: BleNitroLaunch.mm implements the C function
 * with it, since the app target includes only plain C headers of this pod.
 */
@objc(BleNitroLaunch)
public final class BleNitroLaunch: NSObject {
    @objc(didFinishLaunchingWithRestoreIdentifier:)
    public static func didFinishLaunching(restoreIdentifier: String) {
        SharedCentral.launch(restoreIdentifier: restoreIdentifier)
    }
}
