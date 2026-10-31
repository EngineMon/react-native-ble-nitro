import Foundation

/**
 * One value per key for the life of the process, made on first use and never released:
 * CentralHost's registry of the hosts with a restore identifier, one per identifier.
 *
 * Requirement: two values for one key must never exist, whichever threads ask first.
 * Two hosts with one restore identifier would make two CBCentralManagers with it, and
 * CoreBluetooth hands the restored state to only one of them. The first lookup of a key
 * may come from the app's launch hook (main thread, or any thread the app calls it on)
 * and from a JS or C++ thread creating a manager, so `value(for:make:)` makes the value
 * under the lock: `make` must be quick and must not look up this registry.
 *
 * Thread-safe.
 */
final class ProcessRegistry<Value: AnyObject>: @unchecked Sendable {
    /// Guards `values`.
    private let lock = NSLock()
    private var values: [String: Value] = [:]

    /// The value of `key`, made by `make` on the first lookup of `key`.
    func value(for key: String, make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] {
            return value
        }
        let value = make()
        values[key] = value
        return value
    }
}
