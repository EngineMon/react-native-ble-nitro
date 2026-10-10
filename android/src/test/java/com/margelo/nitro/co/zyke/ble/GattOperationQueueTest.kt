package com.margelo.nitro.co.zyke.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/** Unit tests for [GattOperationQueue], on a manual clock instead of a Handler. */
class GattOperationQueueTest {
    /** Runs scheduled tasks when [advance] moves the clock past their due time. */
    private class FakeTimer : OperationTimer {
        private var now = 0L
        private val tasks = mutableListOf<Pair<Long, Runnable>>()

        override fun schedule(task: Runnable, delayMs: Long) {
            tasks += (now + delayMs) to task
        }

        override fun cancel(task: Runnable) {
            tasks.removeAll { it.second === task }
        }

        fun advance(ms: Long) {
            now += ms
            while (true) {
                val due = tasks.filter { it.first <= now }.minByOrNull { it.first } ?: return
                tasks.remove(due)
                due.second.run()
            }
        }
    }

    private inner class TestOperation(private val name: String, private val startError: BleError? = null) : GattOperation {
        override val description = name

        override fun start(): BleError? {
            log += "start $name"
            return startError
        }

        override fun fail(error: BleError) {
            log += "fail $name ${error.code}"
        }
    }

    private val timer = FakeTimer()
    private val queue = GattOperationQueue(timer, TIMEOUT_MS)
    private val log = mutableListOf<String>()

    private fun complete(operation: GattOperation, name: String) = queue.complete(operation) { log += "done $name" }

    @Test
    fun runsOneOperationAtATimeInEnqueueOrder() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        val c = TestOperation("c")
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(c)
        assertEquals(listOf("start a"), log)

        complete(a, "a")
        complete(b, "b")

        assertEquals(listOf("start a", "done a", "start b", "done b", "start c"), log)
        assertSame(c, queue.current)
    }

    @Test
    fun startFailureFailsTheOperationAndStartsTheNext() {
        val a = TestOperation("a", startError = bleError(BleErrorCode.OPERATIONSTARTFAILED, "refused"))
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        assertEquals(listOf("start a", "fail a OPERATIONSTARTFAILED", "start b"), log)
        assertSame(b, queue.current)
    }

    @Test
    fun resultIsDeliveredBeforeTheNextOperationStartsOrFails() {
        val a = TestOperation("a")
        val b = TestOperation("b", startError = bleError(BleErrorCode.OPERATIONSTARTFAILED, "refused"))
        queue.enqueue(a)
        queue.enqueue(b)

        complete(a, "a")

        assertEquals(listOf("start a", "done a", "start b", "fail b OPERATIONSTARTFAILED"), log)
        assertNull(queue.current)
    }

    @Test
    fun timeoutFailsTheOperationAndMovesOn() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(TIMEOUT_MS - 1)
        assertEquals(listOf("start a"), log)
        timer.advance(1)
        assertEquals(listOf("start a", "fail a OPERATIONTIMEDOUT", "start b"), log)

        // The late callback of the timed-out operation is ignored.
        assertFalse(complete(a, "a"))
        // The next operation got a full timeout of its own.
        timer.advance(TIMEOUT_MS - 1)
        assertEquals(listOf("start a", "fail a OPERATIONTIMEDOUT", "start b"), log)
        assertSame(b, queue.current)
    }

    @Test
    fun completionCancelsTheTimeout() {
        val a = TestOperation("a")
        queue.enqueue(a)
        complete(a, "a")

        timer.advance(TIMEOUT_MS * 2)

        assertEquals(listOf("start a", "done a"), log)
    }

    @Test
    fun failAllFailsTheRunningAndEveryWaitingOperationInOrder() {
        queue.enqueue(TestOperation("a"))
        queue.enqueue(TestOperation("b"))
        queue.enqueue(TestOperation("c"))

        queue.failAll(bleError(BleErrorCode.DEVICEDISCONNECTED, "link lost"))
        timer.advance(TIMEOUT_MS * 2)

        assertEquals(
            listOf("start a", "fail a DEVICEDISCONNECTED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"),
            log,
        )
        assertNull(queue.current)
    }

    @Test
    fun operationEnqueuedByACompletionRunsAfterTheOnesAlreadyWaiting() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        val c = TestOperation("c")
        queue.enqueue(a)
        queue.enqueue(b)

        queue.complete(a) {
            log += "done a"
            queue.enqueue(c)
        }
        complete(b, "b")

        assertEquals(listOf("start a", "done a", "start b", "done b", "start c"), log)
    }

    @Test
    fun completingAnOperationThatIsNotInFlightIsIgnored() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        assertFalse(complete(b, "b"))

        assertEquals(listOf("start a"), log)
        assertSame(a, queue.current)
    }

    private companion object {
        const val TIMEOUT_MS = 30_000L
    }
}
