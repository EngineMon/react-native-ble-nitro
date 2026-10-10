package com.margelo.nitro.co.zyke.ble

import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one place that wraps user callbacks, and the one place the rules of
 * NativeBleNitro.nitro.ts, section "After destroy()", are applied to them.
 *
 * The facade wraps every callback it receives exactly once, through this
 * gate, into the type its role needs; everything below the facade accepts only
 * those types ([Reply], [Once], [Listener], [Failable]), so an unwrapped
 * callback can't reach internal code. The gate closes once, when destroy() is
 * called, and from then on:
 * - [listener] and [event] (updates, subscription ends, disconnect callbacks,
 *   state, connection events, scan results, a running scan's end) stay
 *   silent: no listener fires after destroy() was called;
 * - [reply] and [scanStartFailure] (every completion) still complete exactly
 *   once, but with BluetoothManagerDestroyed, whatever internal path completes
 *   them: a call made after destroy(), an operation the teardown ends, or an OS
 *   answer that was already queued ahead of the teardown.
 *
 * The rules hold by construction, checked at delivery, so no internal emit
 * point can forget them. A delivery that passed the check may still be
 * running when the gate closes; BleCore.destroy() waits for it (the barrier),
 * which is why the check alone is enough for its guarantee that no listener
 * runs once destroy() returned.
 *
 * Thread-safe: the gate is read on the manager's executor and closed on any
 * thread.
 */
internal class CallbackGate {
    private val open = AtomicBoolean(true)

    /** True until [close]. */
    val isOpen: Boolean
        get() = open.get()

    /** Closes the gate; true for the call that closed it, false when it was closed already. */
    fun close(): Boolean = open.compareAndSet(true, false)

    /** A repeating listener; silent once the gate is closed. */
    fun <T> listener(onValue: (value: T) -> Unit): Listener<T> = Listener { value -> if (isOpen) onValue(value) }

    /** A one-shot listener (a subscription's end, a disconnect callback); silent once the gate is closed. */
    fun <T> event(fire: (value: T) -> Unit): Once<T> = Once { value -> if (isOpen) fire(value) }

    /** A completion; delivers BluetoothManagerDestroyed instead of the result once the gate is closed. */
    fun <T> reply(deliver: (error: BleError?, value: T?) -> Unit): Reply<T, BleError> = Reply { error, value ->
        if (isOpen) deliver(error, value) else deliver(destroyedError(), null)
    }

    /**
     * A scan start that failed before it reached the OS: a completion of the
     * startScan call, so BluetoothManagerDestroyed once the gate is closed.
     * Mutually exclusive with [scanEnded] of the same scan: a start that failed
     * leaves no scan to end.
     */
    fun scanStartFailure(fail: (error: BleError) -> Unit): Failable<BleError> =
        ScanStartFailure(Once { error -> fail(if (isOpen) error else destroyedError()) })

    /** The end of a running scan (the OS failed it, Bluetooth turned off): an event, silent once the gate is closed. */
    fun scanEnded(fail: (error: BleError) -> Unit): Once<BleError> = event(fail)

    private class ScanStartFailure(private val once: Once<BleError>) : Failable<BleError> {
        override fun fail(error: BleError) = once.fire(error)
    }
}
