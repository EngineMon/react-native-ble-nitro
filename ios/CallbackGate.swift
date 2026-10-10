import Foundation

/**
 * Wraps every user callback of one manager, and applies the rules of
 * NativeBleNitro.nitro.ts, section "After destroy()" from the moment destroy() is called. The
 * facade creates one gate and passes it to BleCore, and wraps each callback through it
 * exactly once. Every after-destroy rule is applied here, where callbacks are wrapped, so
 * it holds for every path that fires them by construction, not by a check at each call
 * site.
 *
 * Why the gate closes before the teardown: destroy() can't do its teardown before
 * returning. The callbacks the teardown fires must run on the manager's queue, never inline
 * on the caller (NativeBleNitro.nitro.ts, section "Threading"). So work already queued ahead of the
 * teardown (a notification, a scan result, a state change CoreBluetooth delivered) would
 * still reach listeners, and the teardown itself would fire ended and disconnect callbacks
 * and Disconnected events. destroy() closes this gate on the caller's thread before it
 * posts the teardown. A delivery that passed the check just before the gate closed may
 * still be running; destroy() waits for it (BleCore.destroy).
 *
 * The vocabulary, the same on Android (CallbackGate.kt):
 * - `listener`: a repeating callback (updates, state, connection events, scan results).
 *   Silent once closed.
 * - `event`: a one-shot listener (endedCallback, disconnect callback, restore callback).
 *   Silent once closed.
 * - `reply`: an operation's completion. It still fires once closed, since a caller waits
 *   for it, but always with BluetoothManagerDestroyed, whatever produced it: a call
 *   rejected at its start, an OS answer already queued ahead of the teardown, an
 *   operation the teardown failed.
 * - `scanStartFailure`: a scan whose start hadn't reached the OS. Like `reply`, it fires
 *   BluetoothManagerDestroyed once closed.
 * - `scanEnded`: the end of a running scan (Bluetooth turned off). Like `event`, it is
 *   silent once closed: the spec ends a running scan silently on destroy.
 *
 * BleCore reads `isOpen` too: from the destroy() call on, synchronous getters return their
 * empty values and no new OS work starts (BleCore.isDestroying), also on the queue before
 * the teardown ran.
 *
 * Thread-safe: closed on any thread, read on the queue and on callers' threads.
 */
final class CallbackGate: @unchecked Sendable {
    /// Guards `open`.
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    /// Closes the gate. Returns true for the call that closed it, false once it was closed.
    @discardableResult
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasOpen = open
        open = false
        return wasOpen
    }

    /// A repeating callback that fires only while the gate is open.
    func listener<Value>(_ callback: @escaping (Value) -> Void) -> Listener<Value> {
        return Listener { [self] value in
            if isOpen {
                callback(value)
            }
        }
    }

    /// A one-shot listener that fires only while the gate is open.
    func event<Value>(_ callback: @escaping (Value) -> Void) -> Once<Value> {
        return Once { [self] value in
            if isOpen {
                callback(value)
            }
        }
    }

    /// An operation's completion. Once the gate is closed it delivers BluetoothManagerDestroyed instead of its outcome.
    func reply<Value>(_ callback: @escaping (BleError?, Value?) -> Void) -> Reply<Value, BleError> {
        return Reply { [self] error, value in
            if isOpen {
                callback(error, value)
            } else {
                callback(destroyedError(), nil)
            }
        }
    }

    /// A scan's start failure: a completion, BluetoothManagerDestroyed once the gate is closed.
    func scanStartFailure(_ callback: @escaping (BleError) -> Void) -> ScanStartFailure {
        return ScanStartFailure(Once { [self] error in
            callback(isOpen ? error : destroyedError())
        })
    }

    /// A running scan's end: an event, silent once the gate is closed.
    func scanEnded(_ callback: @escaping (BleError) -> Void) -> Once<BleError> {
        return event(callback)
    }
}

/**
 * A scan's start failure (`CallbackGate.scanStartFailure`), the scan's completion while
 * its start hasn't reached the OS. It is a `Failable`, so BleCore can reject and fail it
 * like an operation's `Reply`. At most once (`Once`).
 */
final class ScanStartFailure: Failable, Sendable {
    private let once: Once<BleError>

    fileprivate init(_ once: Once<BleError>) {
        self.once = once
    }

    func fail(_ error: BleError) {
        once.fire(error)
    }
}
