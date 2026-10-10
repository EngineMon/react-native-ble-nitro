package com.margelo.nitro.co.zyke.ble

/**
 * What one CCCD operation does for its caller: one operation runs per
 * subscribe call and per unsubscribe call, holding this request.
 */
internal sealed interface CccdRequest<Key, E> {
    /** The characteristic whose CCCD the operation may write. */
    val key: Key

    /** Turn delivery on for subscriber [id] (added to the hub before the operation was enqueued). */
    class Subscribe<Key, E>(val id: Long, override val key: Key) : CccdRequest<Key, E>

    /** Turn the CCCD off if subscriber removal left [key] without subscribers; [reply] is the unsubscribe call's. */
    class Unsubscribe<Key, E>(override val key: Key, val reply: Reply<Unit, E>) : CccdRequest<Key, E>
}

/**
 * The notification subscriptions of one link, and what each characteristic's
 * CCCD (Client Characteristic Configuration descriptor) is known to hold.
 * One hub per link: a new link starts with a new hub. [E] is the error type;
 * the hub builds one error itself, through [cancelledError].
 *
 * Subscriptions:
 * - Any number per characteristic, each under its own [IdSource] id: a
 *   subscribe adds a subscriber, it never replaces another one, and removing
 *   one never affects the others.
 * - A subscriber is Pending from [add] until its subscribe operation
 *   [finish]es: success makes it Active, failure removes it and fails its
 *   completion. Values reach Pending and Active subscribers ([deliver]): the
 *   platform code installs delivery before the CCCD write, because the
 *   peripheral may notify as soon as it got the write, and those first
 *   notifications must not be lost.
 * - [remove] (the owner unsubscribing) stops delivery to the subscriber at
 *   once; a Pending one's completion fails with OperationCancelled. Its
 *   `onEnded` never fires.
 * - [endAll] / [endKeys] (link lost, disconnect, destroy, timeout, services
 *   changed): every ended Pending subscriber's completion fails with the
 *   error, every ended Active subscriber's `onEnded` fires once with it.
 *
 * CCCD reference counting: the CCCD is turned on with the first subscriber of
 * a characteristic and off after the last. One CCCD operation runs per
 * subscribe and per unsubscribe call ([CccdRequest]), in the link's operation
 * queue. It decides what to write when it starts ([plan]), from the state
 * left by every operation before it, not from the state when it was
 * enqueued, and reports its outcome through [finish], its one exit. Each
 * operation owns only its own caller's outcome:
 * - A subscribe operation writes ON only when its own subscriber is still
 *   present and the CCCD isn't known to be on; otherwise it succeeds without
 *   a write (another subscriber's operation already turned it on, or its
 *   subscriber was removed and the removal's own operation handles the rest).
 * - An unsubscribe operation writes OFF only when the characteristic has no
 *   subscriber left and the CCCD isn't known to be off.
 * - A failed write is reported to that operation's caller only; the other
 *   subscribers are settled by their own operations, which try again because
 *   a failed write makes the tracked state Unknown.
 *
 * Tracked CCCD state (per characteristic): Off, On or Unknown. Off on a fresh
 * link: the Bluetooth Core Specification resets the CCCD of a non-bonded
 * client at each connection (Vol 3 Part G §3.3.3.3); a bonded peripheral may
 * keep it on, and then its notifications without a subscriber are dropped and
 * the first subscribe writes ON again, both harmless. A successful write sets
 * it to the written value; a failed or unanswered one sets Unknown, as the
 * peripheral's value can't be known then (the write may have been applied
 * and only its response lost), so the next operation writes in either
 * direction. On iOS, the OS's own notifying flag is authoritative and seeds
 * the state at every plan (the `osNotifying` argument, required so the seed
 * can't be forgotten; Android passes null).
 *
 * Generations: [generation] counts the database invalidations of the link
 * ([endAll], [endKeys]); the platform code records it when an operation
 * starts and doesn't apply results of an older generation. A CCCD write's
 * result is checked here, per characteristic: [finish] ignores it when that
 * characteristic's state was reset by an end after the plan (the plan holds
 * the characteristic's state object, which an end replaces), but still
 * applies it when only other characteristics ended (dropping it would leave
 * the state wrong, and a later last unsubscribe would skip its OFF write).
 *
 * Every state change of a method completes before any callback of it fires:
 * a C++ callback runs inline on the executor and may call synchronous getters
 * (e.g. [isSubscribed]), which must already see the new state.
 *
 * Not thread-safe: confined to the manager's executor.
 */
internal class NotificationHub<Key : Any, Value, E>(
    /** Builds the OperationCancelled error of a Pending subscriber removed by its owner, from a message the hub formats. */
    private val cancelledError: (message: String) -> E,
) {
    private enum class CccdState { OFF, ON, UNKNOWN }

    private inner class Subscriber(
        val id: Long,
        val key: Key,
        val onValue: Listener<Value>,
        val completion: Reply<Unit, E>,
        val onEnded: Once<E>?,
    ) {
        /** GONE once removed or ended, so a delivery already walking an older list skips it. */
        var state = State.PENDING
    }

    private enum class State { PENDING, ACTIVE, GONE }

    /**
     * One characteristic: its subscribers and its tracked CCCD state. Kept
     * after the last subscriber left (the CCCD may still be on, and an
     * operation in flight may still report a write to it); dropped only by
     * [endAll]/[endKeys], which reset the characteristic. A plan holds the
     * channel it was made for, so its identity tells a current plan from one
     * made before a reset.
     */
    private inner class Channel {
        /** Copy-on-write, so [deliver] can walk the list it started with, without copying it per notification. */
        var subscribers: List<Subscriber> = emptyList()
        var tracked = CccdState.OFF
    }

    /** What a CCCD operation does when it starts. Hand it back to [finish] with the operation's outcome. */
    class CccdPlan internal constructor(
        /**
         * Whether the characteristic has any subscriber now: the notification
         * state the OS should deliver for it. Android passes it to
         * setCharacteristicNotification at every CCCD operation start, write or
         * not.
         */
        val enable: Boolean,
        /** Whether the operation writes [enable] to the CCCD. When false it completes without a write. */
        val write: Boolean,
        /** The hub's state object of the characteristic, compared by identity in [finish]. */
        internal val channel: Any,
    )

    /** Subscribers by id, in subscription order (the order in which ends fire). */
    private val subscribers = LinkedHashMap<Long, Subscriber>()
    private val channels = HashMap<Key, Channel>()

    /** Bumped by every [endAll] and [endKeys], whether or not anything ended. */
    var generation = 0L
        private set

    /**
     * Registers a Pending subscriber of [key] under [id], a fresh [IdSource] id
     * (a duplicate is a programming error). It receives values from now on.
     * [completion] reports the outcome of its subscribe operation; [onEnded]
     * fires when the subscription ends without its owner removing it.
     */
    fun add(id: Long, key: Key, onValue: Listener<Value>, completion: Reply<Unit, E>, onEnded: Once<E>?) {
        require(id !in subscribers) { "Subscription id $id is already registered" }
        val subscriber = Subscriber(id, key, onValue, completion, onEnded)
        subscribers[id] = subscriber
        val channel = channel(key)
        channel.subscribers = channel.subscribers + subscriber
    }

    /**
     * Removes subscriber [id]: delivery to it stops at once, a Pending one's
     * completion fails with OperationCancelled. Returns its characteristic,
     * whose unsubscribe operation the caller enqueues next; null when [id] is
     * unknown or already ended (nothing to do: the caller reports success).
     */
    fun remove(id: Long): Key? {
        val subscriber = subscribers.remove(id) ?: return null
        val wasPending = subscriber.state == State.PENDING
        detach(subscriber)
        if (wasPending) subscriber.completion.fail(cancelledError("Subscription $id was unsubscribed before it completed"))
        return subscriber.key
    }

    /**
     * The plan of [request]'s CCCD operation, made when the operation starts.
     * [osNotifying] (iOS: the characteristic's isNotifying; Android: null)
     * replaces the tracked state first.
     */
    fun plan(request: CccdRequest<Key, E>, osNotifying: Boolean?): CccdPlan {
        val channel = channel(request.key)
        if (osNotifying != null) channel.tracked = if (osNotifying) CccdState.ON else CccdState.OFF
        val enable = channel.subscribers.isNotEmpty()
        val write = when (request) {
            is CccdRequest.Subscribe -> subscribers[request.id]?.key == request.key && channel.tracked != CccdState.ON
            is CccdRequest.Unsubscribe -> !enable && channel.tracked != CccdState.OFF
        }
        return CccdPlan(enable, write, channel)
    }

    /**
     * The one exit of [request]'s CCCD operation, on every path: its answer
     * ([cause] null), a completion without a write, and a failure by the
     * queue ([cause] set). [plan] is the operation's plan, null when it failed
     * before planning. [error] null means success.
     *
     * 1. When [plan] writes, records the write's result: success sets the
     *    tracked state to the written value, any error sets Unknown (the
     *    write may have reached the peripheral). Ignored, and logged, when
     *    the characteristic was reset by [endAll]/[endKeys] after the plan.
     * 2. Subscribe: settles its own subscriber. Success makes it Active and
     *    completes it; an error removes it and fails its completion with that
     *    error. Ignored when the subscriber was removed or ended (it was told
     *    already); a second settle is ignored and logged. Except when the
     *    queue closed ([FailCause.QUEUE_CLOSED]): the subscriber stays
     *    Pending, and the [endAll]/[endKeys] of the same close fails its
     *    completion with what ended the link (NativeBleNitro.nitro.ts,
     *    subscribeToCharacteristic: a pending subscribe that fails because
     *    the link ended reports what ended it, e.g. OperationTimedOut after a
     *    stall or BluetoothManagerDestroyed, not the queue's close error).
     *    Invariant this relies on: an owner that closes a link's queue ends
     *    the link's hub in the same close funnel.
     * 3. Unsubscribe: succeeds on success, and also when the queue closed
     *    before it completed ([FailCause.QUEUE_CLOSED]): the subscription is
     *    already gone and the link is going down, which stops delivery
     *    anyway. Any other error fails it: a refused or failed CCCD write,
     *    and a timeout (NativeBleNitro.nitro.ts, Timeouts: an unsubscribe the
     *    OS doesn't answer fails with OperationTimedOut, like every other
     *    operation).
     */
    fun finish(request: CccdRequest<Key, E>, plan: CccdPlan?, error: E?, cause: FailCause?) {
        if (plan != null && plan.write) recordWrite(request.key, plan, error)
        when (request) {
            is CccdRequest.Subscribe -> if (cause != FailCause.QUEUE_CLOSED) settle(request.id, error)
            is CccdRequest.Unsubscribe ->
                if (error == null || cause == FailCause.QUEUE_CLOSED) request.reply.succeed() else request.reply.fail(error)
        }
    }

    /**
     * Hands a value of one notification of [key] to every Pending and Active
     * subscriber, in subscription order. [makeValue] makes that value (e.g.
     * copies the notification's bytes into a new buffer): it is called once
     * per subscriber that receives it, right before that subscriber's
     * callback, and never when no subscriber does. Requirement: every
     * subscriber gets a value of its own (a buffer handed to JS or C++ may be
     * kept, or written to, by its receiver, which must not affect the
     * others), and a notification nobody receives costs no copy. Taking a
     * factory instead of a value makes both hold by construction: the caller
     * can't share one buffer, or copy for nobody.
     */
    fun deliver(key: Key, makeValue: () -> Value) {
        val snapshot = channels[key]?.subscribers ?: return
        for (i in snapshot.indices) {
            val subscriber = snapshot[i]
            if (subscriber.state != State.GONE) subscriber.onValue.emit(makeValue())
        }
    }

    /**
     * Ends every subscription with [error] and resets every characteristic's
     * tracked state: the hub is empty afterwards. Pending completions fail
     * first, then Active subscribers' `onEnded` fire, each group in
     * subscription order.
     */
    fun endAll(error: E) {
        val ended = subscribers.values.toList()
        subscribers.clear()
        channels.clear()
        generation++
        end(ended, error)
    }

    /** [endAll] for the characteristics matching [predicate] only (those of invalidated services). */
    fun endKeys(error: E, predicate: (Key) -> Boolean) {
        val ended = subscribers.values.filter { predicate(it.key) }
        for (subscriber in ended) subscribers.remove(subscriber.id)
        channels.keys.removeAll(predicate)
        generation++
        end(ended, error)
    }

    /** Whether [key] has an Active subscriber (one whose subscribe operation succeeded). */
    fun isSubscribed(key: Key): Boolean =
        channels[key]?.subscribers?.any { it.state == State.ACTIVE } == true

    private fun channel(key: Key): Channel = channels.getOrPut(key) { Channel() }

    private fun recordWrite(key: Key, plan: CccdPlan, error: E?) {
        val channel = channels[key]
        if (channel == null || channel !== plan.channel) {
            bleLog("The CCCD write result of $key arrived after its subscriptions were ended; ignored")
            return
        }
        channel.tracked = when {
            error != null -> CccdState.UNKNOWN
            plan.enable -> CccdState.ON
            else -> CccdState.OFF
        }
    }

    private fun settle(id: Long, error: E?) {
        val subscriber = subscribers[id] ?: return
        if (subscriber.state != State.PENDING) {
            bleLogWithCallStack("Subscription $id was settled twice; the second outcome is ignored")
            return
        }
        if (error == null) {
            subscriber.state = State.ACTIVE
            subscriber.completion.succeed()
        } else {
            subscribers.remove(id)
            detach(subscriber)
            subscriber.completion.fail(error)
        }
    }

    /** Takes [subscriber] (already out of [subscribers]) out of delivery. */
    private fun detach(subscriber: Subscriber) {
        subscriber.state = State.GONE
        val channel = channels[subscriber.key] ?: return
        channel.subscribers = channel.subscribers - subscriber
    }

    /** Fires the ends of [ended], already out of the hub's state; marks them gone before the first callback. */
    private fun end(ended: List<Subscriber>, error: E) {
        val pending = ended.filter { it.state == State.PENDING }
        val active = ended.filter { it.state == State.ACTIVE }
        for (subscriber in ended) subscriber.state = State.GONE
        for (subscriber in pending) subscriber.completion.fail(error)
        for (subscriber in active) subscriber.onEnded?.fire(error)
    }
}
