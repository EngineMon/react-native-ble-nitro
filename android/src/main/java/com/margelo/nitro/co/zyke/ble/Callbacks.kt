package com.margelo.nitro.co.zyke.ble

import java.util.concurrent.atomic.AtomicReference

/*
 * The only shapes in which internal code holds a user callback (JS or C++).
 * The manager's facade wraps every callback it receives exactly once, into a
 * [Reply] (one result), a [Once] (one event) or a [Listener] (a stream of
 * events), and every internal signature accepts only these types (or
 * [Failable]), so an unwrapped callback can't reach internal code: it would
 * be a type error. Internal code never takes a raw function where a user
 * callback could go: function types are contravariant in their parameters, so
 * a raw `(error) -> Unit` parameter would accept an unwrapped user callback.
 *
 * What the wrappers guarantee:
 * - At most once ([Reply], [Once]). A user callback that ran twice would
 *   resolve a promise twice or run C++ continuation code twice. Every path
 *   that can end an operation (OS answer, timeout, link loss, destroy) may
 *   race to report it; the first one wins, later ones are ignored and logged
 *   (a second report is a bug worth seeing, never a crash).
 * - A throwing callback never escapes into the caller. fbjni turns an
 *   exception thrown by a C++ callback into a Java exception at the call (a JS
 *   callback only gets queued for the JS thread here, so its errors surface
 *   there). Escaping, it would unwind through the operation queue or the
 *   subscriber fan-out, skip the bookkeeping after the call, or kill the
 *   manager's thread. Every Throwable is caught and logged; none is rethrown.
 * - A one-shot callback is released by its first call, so a JS function (and
 *   everything its closure holds) isn't kept alive by an operation object
 *   that outlives its answer.
 *
 * The core is generic over the error type [E] (the platform code uses the
 * generated BleError), so it depends on no Nitro or Android type.
 *
 * Threading: user callbacks are only invoked on the manager's executor (see
 * the facade). The at-most-once flag is atomic anyway, so a late completion
 * routed to the post-destroy fallback executor can't race a completion on the
 * manager's thread into a double report.
 */

/**
 * Something that reports a failure to a caller: the type internal code takes
 * when all it can do with a caller is fail it (e.g. a call rejected before it
 * started). A plain interface, not a `fun interface`, so a lambda can't
 * become one by SAM conversion: only the facade's wrappers implement it.
 */
internal interface Failable<in E> {
    fun fail(error: E)
}

/**
 * A one-shot completion: delivers either a value ([succeed]) or an error
 * ([fail]) to the callback, at most once. A second completion is ignored and
 * logged with the call stack that tried it.
 */
internal class Reply<T, E>(deliver: (error: E?, value: T?) -> Unit) : Failable<E> {
    private val target = AtomicReference<((error: E?, value: T?) -> Unit)?>(deliver)

    fun succeed(value: T) = complete(null, value) { "success" }

    override fun fail(error: E) = complete(error, null) { "error $error" }

    private inline fun complete(error: E?, value: T?, outcome: () -> String) {
        val callback = target.getAndSet(null)
        if (callback == null) {
            bleLogWithCallStack("A completion was reported twice; the second one (${outcome()}) is ignored")
            return
        }
        invokeGuarded("A completion callback") { callback(error, value) }
    }
}

/** Completes a [Reply] that carries no value. */
internal fun <E> Reply<Unit, E>.succeed() = succeed(Unit)

/**
 * A one-shot event: the first [fire] calls the callback, later ones are
 * ignored and logged (like [Reply], for an event that has no error/value
 * split, e.g. "this subscription ended because of this error").
 */
internal class Once<T>(fire: (value: T) -> Unit) {
    private val target = AtomicReference<((value: T) -> Unit)?>(fire)

    fun fire(value: T) {
        val callback = target.getAndSet(null)
        if (callback == null) {
            bleLogWithCallStack("A one-shot event fired twice; the second one ($value) is ignored")
            return
        }
        invokeGuarded("A one-shot event callback") { callback(value) }
    }
}

/** A repeating callback: every [emit] calls it; a throw is logged and doesn't reach the emitter. */
internal class Listener<T>(private val onValue: (value: T) -> Unit) {
    fun emit(value: T) = invokeGuarded("A listener callback") { onValue(value) }
}

/**
 * Runs a user callback, catching and logging every Throwable it throws.
 * Throwable rather than Exception: an Error out of a callback (e.g. a
 * StackOverflowError) must not unwind through core bookkeeping either.
 */
private inline fun invokeGuarded(what: String, call: () -> Unit) {
    try {
        call()
    } catch (t: Throwable) {
        bleLogThrown("$what threw; the exception is ignored", t)
    }
}
