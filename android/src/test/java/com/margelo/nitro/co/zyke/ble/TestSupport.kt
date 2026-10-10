package com.margelo.nitro.co.zyke.ble

import java.util.Collections
import java.util.logging.Handler
import java.util.logging.LogRecord

/** The error type the tests specialize the core with, standing in for the platform code's BleError. */
internal data class TestError(val code: String, val message: String = "") {
    override fun toString() = code
}

/**
 * A manual clock instead of a Handler: scheduled tasks run when [advance]
 * moves the clock past their due time, earliest first (schedule order among
 * equals).
 */
internal class FakeTimer : OperationTimer {
    private inner class Task(val due: Long, val run: () -> Unit) : ScheduledTask {
        var cancelled = false

        override fun cancel() {
            cancelled = true
        }
    }

    private var now = 0L
    private val tasks = mutableListOf<Task>()

    override fun schedule(task: () -> Unit, delayMs: Long): ScheduledTask =
        Task(now + delayMs, task).also { tasks += it }

    fun advance(ms: Long) {
        now += ms
        while (true) {
            val due = tasks.filter { !it.cancelled && it.due <= now }.minByOrNull { it.due } ?: return
            tasks.remove(due)
            due.run()
        }
    }
}

/**
 * Records what the pure core logs ([coreLog]) instead of printing it, until
 * [close]d. Tests use it to check that an ignored failure was logged, not
 * silently swallowed.
 */
internal class CoreLogCapture : AutoCloseable {
    /** Synchronized: a test may log from several threads. Read it after they finished. */
    val records: MutableList<LogRecord> = Collections.synchronizedList(mutableListOf())

    private val handler = object : Handler() {
        override fun publish(record: LogRecord) {
            records += record
        }

        override fun flush() = Unit

        override fun close() = Unit
    }
    private val printedBefore = coreLog.useParentHandlers

    init {
        coreLog.addHandler(handler)
        coreLog.useParentHandlers = false
    }

    override fun close() {
        coreLog.removeHandler(handler)
        coreLog.useParentHandlers = printedBefore
    }
}

/**
 * Runs garbage collections until [reference] is cleared or the attempts run
 * out; returns whether it was cleared. For tests that check an object is no
 * longer reachable.
 */
internal fun collected(reference: java.lang.ref.WeakReference<*>): Boolean {
    repeat(50) {
        if (reference.get() == null) return true
        System.gc()
        Thread.sleep(10)
    }
    return reference.get() == null
}
