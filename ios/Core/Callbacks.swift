import Foundation

// The shapes a user callback (JS or C++) takes inside the manager.
//
// Requirement: internal code never holds a raw user callback. The facade wraps each
// callback it is handed exactly once, into `Reply` (one result), `Once` (one event) or
// `Listener` (repeating events), and every core and glue signature accepts only these
// types (or `Failable`, implemented only by such wrappers), so passing an unwrapped closure
// inward is a type error and the delivery rules below hold for every callback without
// each call site re-implementing them. A parameter typed as a function would defeat
// that: function types are contravariant in their parameters, so a raw user callback
// `(Failure?) -> Void` is accepted where `(Failure) -> Void` is asked for.
//
// Threading: the wrappers call the callback on the thread that calls them. The manager
// calls them only on its serial queue, never inline on a caller's thread and never from
// a task a caller is blocked waiting on (a synchronous getter must not run a user
// callback). They are Sendable so the facade can hand them from the caller's thread to
// that queue; the wrapped closure is never called concurrently because only that queue
// calls it.
//
// Exceptions: Swift can't catch a C++ exception. Nitro's generated Swift-to-C++
// callback wrappers are `noexcept` (`Func_*_Wrapper::call`), so a C++ callback that
// throws terminates the app (std::terminate) before control returns here. C++
// callbacks handed to the manager must not throw. (The Android mirror can catch them:
// fbjni turns a C++ exception into a Java one there.)

/**
 * Something a caller waits on that can fail: what internal code takes when all it may
 * do with a caller is fail it (reject an invalid request, fail a request after the
 * manager was destroyed). Implemented by `Reply` and the glue's own one-shot
 * completion wrappers, never by a raw closure.
 *
 * Swift note: take it generically (`<F: Failable>(failing: F) where F.Failure ==
 * BleError`), not as `any Failable<BleError>`: a parameterized existential needs
 * runtime support that iOS has only from 16.0, below this pod's deployment target.
 */
protocol Failable<Failure>: AnyObject, Sendable {
    associatedtype Failure

    /// Fails the caller with `error`, at most once (see `Reply`).
    func fail(_ error: Failure)
}

/**
 * The one-shot completion of an operation: delivers either a value or an error, once.
 *
 * At most once: the first `succeed`/`fail` delivers; every later call is ignored and
 * logged. Several paths can legitimately race to finish the same operation (its OS
 * answer, its timeout, the link going down, the manager being destroyed), and a
 * completion delivered twice would resolve a JS promise twice or run a C++
 * continuation twice. The first delivery also drops the wrapped callback, so whatever
 * it captured (a JS function, a C++ closure) is released right away.
 *
 * Generic over the error type so the core doesn't depend on the generated Nitro
 * types; the glue specializes it with `BleError`.
 */
final class Reply<Value, Failure>: Failable, @unchecked Sendable {
    /// Guards `deliver`, so at most once holds even if two threads were to race.
    private let lock = NSLock()
    /// The callback until the first completion takes it.
    private var deliver: ((Failure?, Value?) -> Void)?

    /// `deliver` receives `(nil, value)` on success and `(error, nil)` on failure.
    init(_ deliver: @escaping (Failure?, Value?) -> Void) {
        self.deliver = deliver
    }

    func succeed(_ value: Value) {
        take("success")?(nil, value)
    }

    func fail(_ error: Failure) {
        take("error \(error)")?(error, nil)
    }

    /// The callback for the first completion; nil, logged, for every later one.
    private func take(_ outcome: @autoclosure () -> String) -> ((Failure?, Value?) -> Void)? {
        lock.lock()
        let callback = deliver
        deliver = nil
        lock.unlock()
        if callback == nil {
            bleLogWithCallStack("A completion was reported twice; the second one (\(outcome())) is ignored")
        }
        return callback
    }
}

extension Reply where Value == Void {
    /// Completes an operation that has no result value.
    func succeed() {
        succeed(())
    }
}

/**
 * A callback for an event that happens at most once, e.g. a subscription ending
 * without its owner unsubscribing.
 *
 * At most once: the first `fire` delivers, every later one is ignored and logged, and
 * the first one drops the wrapped callback (see `Reply`).
 */
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func fire(_ value: Value) {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        guard let pending else {
            bleLogWithCallStack("A one-shot event fired twice; the second one (\(value)) is ignored")
            return
        }
        pending(value)
    }
}

/**
 * A callback for a repeating event: notifications, state changes, connection events.
 * Every `emit` delivers.
 */
final class Listener<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func emit(_ value: Value) {
        callback(value)
    }
}
