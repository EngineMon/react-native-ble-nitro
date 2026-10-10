/**
 * The notification subscriptions of one link and the CCCD state behind them.
 *
 * Requirements:
 * - Subscriptions add, they don't replace: any number of subscribers per
 *   characteristic, each with its own id, its own callbacks and its own end. Removing
 *   one never affects another.
 * - The CCCD (Client Characteristic Configuration descriptor, Core Vol 3 Part G
 *   §3.3.3.3) is per characteristic and per link, so it is reference-counted: on with
 *   the first subscriber, off after the last. One CCCD operation per subscribe and per
 *   unsubscribe call (`CccdRequest`) decides what to write when it starts (`plan`), so
 *   it sees the state left by every operation queued before it:
 *   - a subscribe operation writes ON only if its own subscriber is still there and the
 *     tracked state isn't ON;
 *   - an unsubscribe operation writes OFF only if the key has no subscribers left and
 *     the tracked state isn't OFF;
 *   - otherwise it writes nothing and succeeds. A failed write is reported only to the
 *     caller of the operation that made it.
 *   Every exit of the operation goes through one call, `finish`, which records the
 *   write's result and settles the operation's own caller, so no exit path can forget
 *   either.
 * - Tracked CCCD state is OFF, ON or UNKNOWN. OFF on a fresh link: a server resets the
 *   CCCD of an unbonded client to 0 at each connection (Core Vol 3 Part G §3.3.3.3; a
 *   bonded device keeps its value: then its notifications without a subscriber are
 *   dropped and the first subscribe writes ON again, both harmless). UNKNOWN after a
 *   failed or unanswered write: the device may have applied it and only the response
 *   got lost, so the next operation of either kind writes. On iOS
 *   `CBCharacteristic.isNotifying` is authoritative (restored or already-notifying
 *   characteristics need no write), so the glue seeds the state with it at every plan.
 *   `plan` takes the seed as a required argument (nil on Android, which has no such
 *   state), so a call site can't leave it out by accident.
 * - A subscriber is Pending (subscribed, CCCD not yet confirmed) until its subscribe
 *   operation finishes (`finish`), then Active. Values reach Pending and Active
 *   subscribers: the value handler is in place before the CCCD write, so the first
 *   notifications after the device starts notifying aren't lost.
 * - `remove` stops delivery to its subscriber at once. A Pending subscriber's
 *   completion fails with OperationCancelled; `onEnded` never fires for a subscriber
 *   its owner removed.
 * - When subscriptions end without their owners (link down, manager destroyed,
 *   operation timeout, services changed: `endAll`/`endKeys`), every Pending
 *   subscriber's completion fails and every Active subscriber's `onEnded` fires once,
 *   with the error.
 * - Generations: every `endAll`/`endKeys` starts a new `generation`, even when no
 *   subscriber matched (the call itself means the link ended or its database changed).
 *   The glue records it when an operation starts and doesn't apply a result from an
 *   older generation (a discovery that overlapped a database change fails). The hub
 *   applies the same rule per key to CCCD results: `endAll`/`endKeys` reset the keys
 *   they end, and a write planned before the reset doesn't touch the new state. Per
 *   key, so a change to service A can't discard the CCCD result of an untouched key
 *   of service B (its tracked state would go wrong, and a later last unsubscribe would
 *   skip the OFF write).
 * - Collect, then fire: every method finishes its state change before it calls any
 *   callback, so a callback that reads the hub (a C++ callback calling a synchronous
 *   getter inline) sees the new state.
 *
 * Not thread-safe and not Sendable: confined to the manager's serial queue, which also
 * runs every callback.
 */
final class NotificationHub<Key: Hashable, Value, Failure> {
    /**
     * The request behind one CCCD operation: the subscribe or unsubscribe call it
     * serves. The glue's operation holds it from enqueue to `finish`.
     */
    enum CccdRequest {
        /// Subscriber `id` (already added) wants notifications of `key` on.
        case subscribe(id: Int64, key: Key)
        /// A subscriber of `key` was removed (`remove`); `reply` is the unsubscribe
        /// call's completion.
        case unsubscribe(key: Key, reply: Reply<Void, Failure>)

        /// The characteristic the request is for.
        var key: Key {
            switch self {
            case .subscribe(_, let key), .unsubscribe(let key, _):
                return key
            }
        }
    }

    /**
     * What a CCCD operation does, decided when it starts (`plan`). The operation hands it
     * back with its result (`finish`).
     */
    struct CccdPlan {
        /// Whether notifications should be on: the key has a subscriber (Pending or
        /// Active). The value to write; the Android glue also passes it to
        /// `setCharacteristicNotification` at every start (local and idempotent).
        let enable: Bool
        /// Whether the operation writes `enable` to the CCCD. False: it succeeds without
        /// a write.
        let write: Bool
        /// The characteristic the plan is for.
        let key: Key
        /// The key's state when the plan was made: a reset replaces it.
        fileprivate let channel: Channel
    }

    fileprivate enum CccdState {
        case off
        case on
        case unknown
    }

    /// One key's subscribers and tracked CCCD state. Lives until `endAll`/`endKeys` end
    /// the key (never dropped on the last unsubscribe), so its identity tells whether
    /// the key was reset since a plan was made.
    fileprivate final class Channel {
        /// In subscription order. `deliver` iterates the array it finds, so a change
        /// during a delivery copies it (copy on write) instead of disturbing the loop.
        var subscribers: [Subscriber] = []
        var tracked = CccdState.off
    }

    fileprivate final class Subscriber {
        enum State {
            case pending
            case active
            /// Removed or ended: gets nothing more, even from a delivery in progress.
            case gone
        }

        let id: Int64
        let key: Key
        let onValue: Listener<Value>
        let completion: Reply<Void, Failure>
        let onEnded: Once<Failure>?
        var state = State.pending

        init(id: Int64, key: Key, onValue: Listener<Value>, completion: Reply<Void, Failure>, onEnded: Once<Failure>?) {
            self.id = id
            self.key = key
            self.onValue = onValue
            self.completion = completion
            self.onEnded = onEnded
        }
    }

    private let cancelledError: (String) -> Failure

    /// Every Pending and Active subscriber, in subscription order. Each one is also in
    /// the channel of its key, and every key of a subscriber has a channel.
    private var subscribers: [Subscriber] = []
    private var channels: [Key: Channel] = [:]

    /// Starts at 0; +1 on every `endAll` and `endKeys`.
    private(set) var generation: Int64 = 0

    /**
     * - Parameter cancelledError: makes the OperationCancelled error a Pending
     *   subscriber's completion fails with when it is removed, from a message the hub
     *   formats.
     */
    init(cancelledError: @escaping (String) -> Failure) {
        self.cancelledError = cancelledError
    }

    /**
     * Adds a Pending subscriber of `key`: values reach `onValue` from now on. Its
     * subscribe operation's `finish` settles it, which completes `completion`. `id`
     * comes from `IdSource`; an id in use is a programming error.
     */
    func add(id: Int64, key: Key, onValue: Listener<Value>, completion: Reply<Void, Failure>, onEnded: Once<Failure>?) {
        precondition(subscriber(id) == nil, "Subscription id \(id) is already in use")
        let subscriber = Subscriber(id: id, key: key, onValue: onValue, completion: completion, onEnded: onEnded)
        subscribers.append(subscriber)
        channel(key).subscribers.append(subscriber)
    }

    /**
     * Removes the subscriber with `id`: nothing reaches it any more, and its `onEnded`
     * never fires. A Pending subscriber's completion fails with OperationCancelled.
     * Returns its key, for the unsubscribe operation, or nil when no subscriber has the
     * id (never added, removed or ended: unsubscribing it is a successful no-op).
     */
    func remove(id: Int64) -> Key? {
        guard let subscriber = subscriber(id) else { return nil }
        let wasPending = subscriber.state == .pending
        detach(subscriber)
        if wasPending {
            subscriber.completion.fail(cancelledError("Subscription \(id) was unsubscribed before it completed"))
        }
        return subscriber.key
    }

    /**
     * What `request`'s CCCD operation does, decided when it starts (after its
     * characteristic resolved). `osNotifying` is the OS's own notifying state when it has
     * one (iOS: `CBCharacteristic.isNotifying`), which replaces the tracked state first;
     * nil when it has none (Android).
     *
     * - Subscribe: writes ON when its own subscriber is still there (under this key) and
     *   the tracked state isn't ON.
     * - Unsubscribe: writes OFF when the key has no subscribers left and the tracked state
     *   isn't OFF.
     */
    func plan(_ request: CccdRequest, osNotifying: Bool?) -> CccdPlan {
        let key = request.key
        let channel = self.channel(key)
        if let osNotifying {
            channel.tracked = osNotifying ? .on : .off
        }
        let enable = !channel.subscribers.isEmpty
        let write: Bool
        switch request {
        case .subscribe(let id, _):
            write = channel.subscribers.contains { $0.id == id } && channel.tracked != .on
        case .unsubscribe:
            write = !enable && channel.tracked != .off
        }
        return CccdPlan(enable: enable, write: write, key: key, channel: channel)
    }

    /**
     * The one exit of `request`'s CCCD operation, from every path: its answer
     * (`error` nil when the device confirmed the write), its completion without a write
     * (`error` nil), or its failure by the queue (`error` and `cause`, from
     * `GattOperation.fail`). `plan` is nil when the operation failed before it planned.
     *
     * In this order:
     * 1. A written plan's result is recorded: success tracks `plan.enable`; any error
     *    tracks UNKNOWN (the write may have been applied and only its answer lost).
     *    Dropped (logged) when the key was reset by `endAll`/`endKeys` since the plan;
     *    applied when only other keys were reset.
     * 2. Subscribe: settles its own subscriber only (others of the key settle through
     *    their own operations): no error → Active, completion succeeds; its own error
     *    (refused, timed out, CCCD write failed) → removed, completion fails with it. A
     *    subscriber already gone (removed or ended meanwhile) was told by that path:
     *    no-op. Failed by the queue closing (`.queueClosed`), it stays Pending: its link
     *    is ending, and the spec gives a subscription that ends before it completed the
     *    error that ended it (SubscriptionEndedCallback: 201 link lost, 3 timeout, 1
     *    destroyed), not the queue's close error. The `endAll`/`endKeys` that follows
     *    every queue close fails it with that error (owner invariant: a link's close
     *    funnel closes its queue and then ends its hub).
     * 3. Unsubscribe: succeeds when there is no error or the queue closed before it
     *    finished (`.queueClosed`: the link went down first, so the subscription is gone
     *    and nothing is left to turn off; spec unsubscribeFromCharacteristic). Fails with
     *    the error otherwise: the device or OS refused the write
     *    (CharacteristicNotifyChangeFailed), its lookup failed, or its own write went
     *    unanswered (`.timedOut`: the spec's Timeouts rule fails every unanswered
     *    operation, unsubscribe included, with OperationTimedOut).
     */
    func finish(_ request: CccdRequest, plan: CccdPlan?, error: Failure?, cause: FailCause?) {
        if let plan, plan.write {
            record(plan, error: error)
        }
        switch request {
        case .subscribe(let id, _):
            if cause != .queueClosed {
                settle(id: id, error: error)
            }
        case .unsubscribe(_, let reply):
            if let error, cause != .queueClosed {
                reply.fail(error)
            } else {
                reply.succeed()
            }
        }
    }

    /**
     * Hands a value of `key` to its Pending and Active subscribers, in subscription
     * order. `makeValue` runs once per receiving subscriber, right before its listener:
     * every subscriber gets a value of its own (spec: each value is a buffer of its own,
     * so one subscriber changing its buffer can't change another's), and a value nobody
     * receives (no subscriber, or one removed or ended earlier in the same delivery)
     * costs no copy.
     */
    func deliver(key: Key, makeValue: () -> Value) {
        guard let channel = channels[key] else { return }
        for subscriber in channel.subscribers where subscriber.state != .gone {
            subscriber.onValue.emit(makeValue())
        }
    }

    /// Ends every subscription with `error` (link down, manager destroyed, operation
    /// timeout, services changed on Android), resets the CCCD state and starts a new
    /// generation.
    func endAll(error: Failure) {
        let ended = subscribers
        subscribers.removeAll()
        channels.removeAll()
        generation += 1
        end(ended, error: error)
    }

    /// Ends the subscriptions of the keys `predicate` selects with `error` (the
    /// characteristics of invalidated services), resets those keys' CCCD state and
    /// starts a new generation.
    func endKeys(error: Failure, where predicate: (Key) -> Bool) {
        let endedKeys = Set(channels.keys.filter(predicate))
        let ended = subscribers.filter { endedKeys.contains($0.key) }
        subscribers.removeAll { endedKeys.contains($0.key) }
        for key in endedKeys {
            channels[key] = nil
        }
        generation += 1
        end(ended, error: error)
    }

    /// Whether `key` has an Active subscriber (a confirmed subscription of this manager).
    func isSubscribed(key: Key) -> Bool {
        return channels[key]?.subscribers.contains { $0.state == .active } ?? false
    }

    /// Records the result of `plan`'s CCCD write (see `finish`).
    private func record(_ plan: CccdPlan, error: Failure?) {
        guard channels[plan.key] === plan.channel else {
            bleLog("The CCCD write result of \(plan.key) arrived after its subscriptions were ended; ignored")
            return
        }
        plan.channel.tracked = error == nil ? (plan.enable ? .on : .off) : .unknown
    }

    /// Settles subscriber `id` with its subscribe operation's outcome (see `finish`).
    private func settle(id: Int64, error: Failure?) {
        guard let subscriber = subscriber(id) else { return }
        guard subscriber.state == .pending else {
            bleLogWithCallStack("Subscription \(id) was settled twice; the second outcome is ignored")
            return
        }
        if let error {
            detach(subscriber)
            subscriber.completion.fail(error)
        } else {
            subscriber.state = .active
            subscriber.completion.succeed()
        }
    }

    /// Fires the ends of subscribers already taken out of the hub: Pending completions
    /// fail, then Active `onEnded`s fire, each group in subscription order.
    private func end(_ ended: [Subscriber], error: Failure) {
        let pending = ended.filter { $0.state == .pending }
        let active = ended.filter { $0.state == .active }
        for subscriber in ended {
            subscriber.state = .gone
        }
        for subscriber in pending {
            subscriber.completion.fail(error)
        }
        for subscriber in active {
            subscriber.onEnded?.fire(error)
        }
    }

    private func subscriber(_ id: Int64) -> Subscriber? {
        return subscribers.first { $0.id == id }
    }

    /// Takes `subscriber` out of the hub and its channel and marks it gone.
    private func detach(_ subscriber: Subscriber) {
        subscribers.removeAll { $0 === subscriber }
        channels[subscriber.key]?.subscribers.removeAll { $0 === subscriber }
        subscriber.state = .gone
    }

    /// The channel of `key`, made (OFF, no subscribers) if the key has none.
    private func channel(_ key: Key) -> Channel {
        if let channel = channels[key] {
            return channel
        }
        let channel = Channel()
        channels[key] = channel
        return channel
    }
}
