import Foundation

/**
 * Hands out the ids of registrations (subscriptions, state and connection-event
 * listeners): positive, increasing, never reused within the process.
 *
 * Requirement: an id names one registration for good. If an id could come back, a
 * late `unsubscribe(id)` (from JS, after its registration already ended) would remove
 * an unrelated newer registration that happened to get the same id. There is one
 * counter per process, not per manager, so ids are unique across every manager by
 * construction.
 *
 * Thread-safe (the one core type that is): the facade allocates the id on the
 * caller's thread so it can return it synchronously, before the registration itself
 * runs on the manager's queue.
 *
 * Range: an Int64 counter can't wrap in practice (one id per nanosecond would take
 * 292 years). The facades hand ids to JS as a Double, exact for every id up to 2^53.
 */
enum IdSource {
    private static let counter = Counter()

    /// The next id: 1 for the first call in the process.
    static func next() -> Int64 {
        return counter.increment()
    }

    private final class Counter: @unchecked Sendable {
        /// Guards `last`.
        private let lock = NSLock()
        private var last: Int64 = 0

        func increment() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            last += 1
            return last
        }
    }
}
