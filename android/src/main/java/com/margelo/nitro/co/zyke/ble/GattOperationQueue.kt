package com.margelo.nitro.co.zyke.ble

/** Why [GattOperationQueue] failed an operation; the operation decides from it what its caller hears. */
internal enum class FailCause {
    /** [GattOperation.start] returned an error: the operation never reached the device. */
    START_REFUSED,

    /** No answer within [GattOperation.timeoutMs]: the link is stalled and is taken down. */
    TIMED_OUT,

    /** The queue was closed (link going down, disconnect, destroy) before the operation completed. */
    QUEUE_CLOSED,
}

/** One GATT procedure waiting in, or running at the head of, a [GattOperationQueue]. [E] is the error type. */
internal interface GattOperation<E> {
    /** What the operation does, for error messages, e.g. "Characteristic read on AA:BB:CC:DD:EE:FF". */
    val description: String

    /**
     * How long the operation may wait for its answer once started, in ms. ATT
     * procedures use [GattRules.ATT_TRANSACTION_TIMEOUT_MS].
     */
    val timeoutMs: Long

    /**
     * Issues the operation to the OS. Returns null when the OS accepted it (the
     * operation then waits for [GattOperationQueue.complete] or its timeout), or
     * the error to fail it with ([FailCause.START_REFUSED]).
     *
     * An operation that already knows its result (e.g. a CCCD operation with
     * nothing to write) may call [GattOperationQueue.complete] for itself from
     * inside [start] and return null; the next operation starts after [start]
     * returned, and an error returned by a [start] that already completed is
     * dropped. An exception thrown by [start] leaves the operation in flight:
     * its timeout ends it.
     */
    fun start(): E?

    /**
     * Reports the operation's failure to its caller, with the reason the
     * queue failed it. Called at most once, and never after it completed.
     */
    fun fail(error: E, cause: FailCause)

    /**
     * Called when [timeoutMs] passed without an answer. Every ATT procedure
     * returns false without reporting anything: the link then stalls (see
     * [GattOperationQueue]) and the operation fails with
     * [FailCause.TIMED_OUT]. An operation whose answer the OS may legitimately
     * never send, and whose outcome is known without it, reports that outcome
     * here and returns true; the queue then starts the next operation.
     * Required, with no default, so every operation states its timeout policy.
     */
    fun settleOnTimeout(): Boolean
}

/** Runs delayed tasks on the queue's thread: a Handler in the app, a fake clock in tests. */
internal interface OperationTimer {
    fun schedule(task: () -> Unit, delayMs: Long): ScheduledTask
}

/** A task scheduled by an [OperationTimer]. */
internal interface ScheduledTask {
    /** Keeps the task from running; no effect once it ran. */
    fun cancel()
}

/**
 * The GATT operations of one link, run one at a time in FIFO order. One queue
 * per link, never reopened: a new link gets a new queue. [E] is the error type,
 * [Op] the operation type the platform code routes answers to ([current]).
 *
 * Requirements:
 * - Android's BluetoothGatt allows one outstanding procedure per connection (it
 *   refuses a second one while the first awaits its callback), and
 *   CoreBluetooth matches answers to requests only by attribute, so exactly
 *   one operation is in flight and the others wait in enqueue order.
 * - An operation completes only through the OS callback that answers it
 *   ([complete], which checks that the answered operation is the one in
 *   flight). That includes a write without response on Android, which
 *   completes on onCharacteristicWrite: the stack's flow control.
 * - Every operation has its own timeout ([GattOperation.timeoutMs]). A timeout
 *   stalls the link and the queue starts nothing else, ever. Bluetooth Core
 *   Specification Vol 3 Part F §3.3.3: an ATT transaction not completed
 *   within 30 s has timed out, and no further ATT PDUs may be sent on that
 *   bearer; Android additionally keeps BluetoothGatt's internal busy flag set
 *   until the late callback, so every following procedure would be refused
 *   as busy. As no operation of the link ever runs again, a late answer can't
 *   complete a later operation of the same kind. An operation that may
 *   settle without its answer opts out through
 *   [GattOperation.settleOnTimeout].
 * - The owner learns of a stall before anyone else: the queue calls [onStall]
 *   first, while the timed-out operation is still unreported (no longer
 *   [current], so its late answer is ignored), and the owner takes the link
 *   down from there: its state changes first, then it [close]s the queue,
 *   which fails the timed-out operation first ([FailCause.TIMED_OUT], with
 *   [timeoutError]), then the waiting ones with the close error. So every
 *   callback, the timed-out operation's included, runs after the owner's
 *   state changed (a C++ callback may call synchronous getters inline, and
 *   must see the link going down, not a link that looks up), and callers hear
 *   about it in queue order: the timed-out operation, the waiting ones, then
 *   whatever the owner ends after the close (subscriptions).
 * - No operation is left unreported, even by an owner that breaks the
 *   contract: when [onStall] returns (or throws) without closing the queue,
 *   the queue logs it and closes itself with the timeout error, so the
 *   waiting and every later operation fail too instead of waiting forever.
 * - [close] fails the running and every waiting operation with its error
 *   ([FailCause.QUEUE_CLOSED]: link lost, disconnect requested, manager
 *   destroyed), and every later [enqueue] fails the operation at once with
 *   that error. Closing from inside a callback of the queue (an operation's
 *   start, failure or result, [onStall]) is safe: the close fails what is
 *   left, and nothing starts afterwards.
 * - Each failure carries its [FailCause], so an operation never has to
 *   rebuild from outside state why it failed.
 * - Results are reported in operation order: nothing starts while a result or
 *   failure is being reported, so a start failure of the next operation can't
 *   overtake it, and an operation enqueued from a result callback starts
 *   after that callback returned, behind the ones already waiting.
 * - Exception safety: an exception thrown while reporting (a bug in platform
 *   code; user callbacks are already guarded by [Reply]/[Listener]) still
 *   propagates, but the queue first starts the next operation, and [close]
 *   fails every operation before rethrowing, so one throw never stalls the
 *   link or leaves an operation unreported.
 *
 * Not thread-safe: all methods run on the manager's executor.
 */
internal class GattOperationQueue<Op : GattOperation<E>, E>(
    private val timer: OperationTimer,
    /** Builds the error of a timed-out operation from a message the queue formats. */
    private val timeoutError: (message: String) -> E,
    /**
     * Called once when an operation's timeout stalled the link, with that
     * operation, before its failure is reported (see the class comment): the
     * owner changes its state, then [close]s the queue.
     */
    private val onStall: (operation: Op) -> Unit,
) {
    private sealed interface State<out E> {
        data object Open : State<Nothing>

        /** An operation timed out; nothing starts again. */
        data object Stalled : State<Nothing>

        class Closed<E>(val error: E) : State<E>
    }

    /** A timed-out operation and its error, held from the stall until it is reported. */
    private class TimedOut<Op, E>(val operation: Op, val error: E)

    private var state: State<E> = State.Open
    private val waiting = ArrayDeque<Op>()
    private var running: Op? = null
    private var timedOut: TimedOut<Op, E>? = null
    private var timeout: ScheduledTask? = null

    /**
     * True while the queue is calling into an operation (start, result,
     * failure, settle): nothing starts until that call returned. Keeps results
     * in order and keeps a start from running nested inside another
     * operation's callback.
     */
    private var inCallout = false

    /** The operation awaiting its OS answer, if any. */
    val current: Op?
        get() = running

    /** True once [close] was called: every later [enqueue] fails at once. */
    val isClosed: Boolean
        get() = state is State.Closed

    /** Runs [operation] after the ones already waiting; fails it at once when the queue is closed. */
    fun enqueue(operation: Op) {
        val closed = state
        if (closed is State.Closed) {
            operation.fail(closed.error, FailCause.QUEUE_CLOSED)
            return
        }
        waiting.addLast(operation)
        startNext()
    }

    /**
     * Completes [operation] if it is the one in flight: [deliver] reports its
     * result, then the next operation starts. Returns false, without calling
     * [deliver], when [operation] is not in flight (it timed out or was failed).
     */
    fun complete(operation: Op, deliver: () -> Unit): Boolean {
        if (running !== operation) return false
        cancelTimeout()
        running = null
        try {
            callout(deliver)
        } finally {
            startNext()
        }
        return true
    }

    /**
     * Fails the operations not yet reported, in queue order: a timed-out one
     * awaiting its report with its timeout error ([FailCause.TIMED_OUT]),
     * then the running and every waiting one with [error]
     * ([FailCause.QUEUE_CLOSED]); every later [enqueue] fails with [error] too.
     * Idempotent: a second close finds nothing to fail and keeps the first
     * error.
     */
    fun close(error: E) {
        if (state is State.Closed) return
        state = State.Closed(error)
        cancelTimeout()
        val stalled = timedOut
        timedOut = null
        val failed = ArrayList<Op>(waiting.size + 1)
        running?.let(failed::add)
        failed.addAll(waiting)
        running = null
        waiting.clear()
        var thrown: Throwable? = null
        fun report(operation: Op, failure: E, cause: FailCause) {
            try {
                operation.fail(failure, cause)
            } catch (t: Throwable) {
                val first = thrown
                if (first == null) thrown = t else first.addSuppressed(t)
            }
        }
        stalled?.let { report(it.operation, it.error, FailCause.TIMED_OUT) }
        for (operation in failed) report(operation, error, FailCause.QUEUE_CLOSED)
        thrown?.let { throw it }
    }

    private fun startNext() {
        while (running == null && !inCallout && state == State.Open) {
            val operation = waiting.removeFirstOrNull() ?: return
            running = operation
            timeout = timer.schedule({ onTimeout(operation) }, operation.timeoutMs)
            val error = callout { operation.start() } ?: continue
            // Settled from inside start() (completed itself, or failed by a
            // close): its outcome is already reported, the error is moot.
            if (running !== operation) continue
            cancelTimeout()
            running = null
            try {
                callout { operation.fail(error, FailCause.START_REFUSED) }
            } catch (t: Throwable) {
                startNext()
                throw t
            }
        }
    }

    private fun onTimeout(operation: Op) {
        if (running !== operation) return
        timeout = null
        running = null
        var settled = false
        try {
            settled = callout { operation.settleOnTimeout() }
        } finally {
            if (settled) startNext() else stall(operation)
        }
    }

    private fun stall(operation: Op) {
        state = State.Stalled
        val error = timeoutError("${operation.description} timed out after ${operation.timeoutMs} ms")
        timedOut = TimedOut(operation, error)
        try {
            onStall(operation)
        } finally {
            if (state !is State.Closed) {
                bleLogWithCallStack("The owner of a stalled queue didn't close it; closing it with the timeout of ${operation.description}")
                close(error)
            }
        }
    }

    private fun cancelTimeout() {
        timeout?.cancel()
        timeout = null
    }

    private inline fun <R> callout(call: () -> R): R {
        val outer = inCallout
        inCallout = true
        try {
            return call()
        } finally {
            inCallout = outer
        }
    }
}
