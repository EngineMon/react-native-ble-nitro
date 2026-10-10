package com.margelo.nitro.co.zyke.ble

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [GattOperationQueue], on a manual clock. Its owner does what
 * the platform code does from `onStall`: marks the link closing, then closes
 * the queue with the link-down error.
 */
class GattOperationQueueTest {
    private inner class TestOperation(
        val name: String,
        private val startError: TestError? = null,
        override val timeoutMs: Long = TIMEOUT_MS,
        private val settlesOnTimeout: Boolean = false,
    ) : GattOperation<TestError> {
        /** Runs inside [start], before it returns. */
        var onStart: (() -> Unit)? = null

        /** Runs inside [fail], after it logged. */
        var onFail: (() -> Unit)? = null

        /** The causes it was failed with. */
        val causes = mutableListOf<FailCause>()

        override val description = name

        override fun start(): TestError? {
            log += "start $name"
            onStart?.invoke()
            return startError
        }

        override fun fail(error: TestError, cause: FailCause) {
            causes += cause
            log += "fail $name ${error.code}"
            onFail?.invoke()
        }

        override fun settleOnTimeout(): Boolean {
            if (!settlesOnTimeout) return false
            log += "settle $name"
            return true
        }
    }

    private val logs = CoreLogCapture()
    private val timer = FakeTimer()
    private val log = mutableListOf<String>()
    private val lost = TestError("DEVICEDISCONNECTED", "link lost")

    /** Set by the owner when it starts taking the link down. */
    private var ownerClosing = false

    /** Runs in the owner's onStall before it closes the queue. */
    private var whileStalling: (() -> Unit)? = null

    private val queue: GattOperationQueue<TestOperation, TestError> = GattOperationQueue(
        timer,
        timeoutError = { TestError("OPERATIONTIMEDOUT", it) },
        onStall = { operation ->
            ownerClosing = true
            log += "stall ${operation.name}"
            whileStalling?.invoke()
            closeQueue()
        },
    )

    private fun closeQueue() = queue.close(lost)

    @After
    fun stopCapturing() = logs.close()

    private fun complete(operation: TestOperation) = queue.complete(operation) { log += "done ${operation.name}" }

    @Test
    fun runsOneOperationAtATimeInEnqueueOrder() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        val c = TestOperation("c")
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(c)
        assertEquals(listOf("start a"), log)

        complete(a)
        complete(b)

        assertEquals(listOf("start a", "done a", "start b", "done b", "start c"), log)
        assertSame(c, queue.current)
    }

    @Test
    fun startFailureFailsTheOperationAndStartsTheNext() {
        val a = TestOperation("a", startError = TestError("OPERATIONSTARTFAILED", "refused"))
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        assertEquals(listOf("start a", "fail a OPERATIONSTARTFAILED", "start b"), log)
        assertSame(b, queue.current)
    }

    @Test
    fun resultIsDeliveredBeforeTheNextOperationStartsOrFails() {
        val a = TestOperation("a")
        val b = TestOperation("b", startError = TestError("OPERATIONSTARTFAILED", "refused"))
        queue.enqueue(a)
        queue.enqueue(b)

        complete(a)

        assertEquals(listOf("start a", "done a", "start b", "fail b OPERATIONSTARTFAILED"), log)
        assertNull(queue.current)
    }

    @Test
    fun operationEnqueuedByACompletionRunsAfterItAndAfterTheOnesAlreadyWaiting() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        val c = TestOperation("c")
        queue.enqueue(a)
        queue.enqueue(b)

        queue.complete(a) {
            queue.enqueue(c)
            log += "done a"
        }
        complete(b)

        assertEquals(listOf("start a", "done a", "start b", "done b", "start c"), log)
    }

    @Test
    fun operationThatCompletesInsideItsOwnStartLetsTheNextStartAfterward() {
        // Its start also returns an error after completing: dropped, a is never failed.
        val a = TestOperation("a", startError = TestError("OPERATIONSTARTFAILED", "moot"))
        a.onStart = {
            queue.complete(a) { log += "done a" }
            log += "a returns from start"
        }
        val b = TestOperation("b")
        val first = TestOperation("first")
        queue.enqueue(first)
        queue.enqueue(a)
        queue.enqueue(b)

        complete(first)

        assertEquals(listOf("start first", "done first", "start a", "done a", "a returns from start", "start b"), log)
        assertSame(b, queue.current)
    }

    @Test
    fun completingAnOperationThatIsNotInFlightIsIgnored() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        assertFalse(complete(b))

        assertEquals(listOf("start a"), log)
        assertSame(a, queue.current)
    }

    @Test
    fun completionCancelsTheTimeout() {
        val a = TestOperation("a")
        queue.enqueue(a)
        complete(a)

        timer.advance(TIMEOUT_MS * 2)

        assertEquals(listOf("start a", "done a"), log)
    }

    @Test
    fun timeoutStallsTheQueueThenFailsTheOperation() {
        val a = TestOperation("a")
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(TIMEOUT_MS - 1)
        assertEquals(listOf("start a"), log)
        timer.advance(1)
        assertEquals(listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED"), log)

        // Nothing runs on a stalled link, and the late answer is ignored.
        timer.advance(TIMEOUT_MS * 2)
        assertFalse(complete(a))
        assertNull(queue.current)
        assertEquals(listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED"), log)
    }

    @Test
    fun operationsEnqueuedAfterAStallWaitForTheClose() {
        queue.enqueue(TestOperation("a"))
        queue.enqueue(TestOperation("b"))
        // Enqueued while the owner handles the stall, before it closes: nothing starts it.
        whileStalling = { queue.enqueue(TestOperation("c")) }

        timer.advance(TIMEOUT_MS)

        assertEquals(
            listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"),
            log,
        )
    }

    @Test
    fun timeoutStallsTheOwnerBeforeTheOperationFails() {
        val a = TestOperation("a")
        val seenByTheFailure = mutableListOf<String>()
        a.onFail = {
            seenByTheFailure += "owner closing $ownerClosing, in flight ${queue.current === a}"
            // A late answer (or one the failure's callback provokes) can't complete it again.
            seenByTheFailure += "completed again ${queue.complete(a) {}}"
        }
        queue.enqueue(a)

        timer.advance(TIMEOUT_MS)

        assertEquals(listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT"), log)
        assertEquals(listOf("owner closing true, in flight false", "completed again false"), seenByTheFailure)
    }

    @Test
    fun closeFromOnStallFailsTheTimedOutOperationFirstThenTheWaitingOnes() {
        queue.enqueue(TestOperation("a"))
        queue.enqueue(TestOperation("b"))

        timer.advance(TIMEOUT_MS)
        queue.enqueue(TestOperation("c"))
        timer.advance(TIMEOUT_MS * 2)

        assertEquals(
            listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"),
            log,
        )
        assertNull(queue.current)
        assertTrue(queue.isClosed)
    }

    @Test
    fun stalledOperationFailsEvenWhenTheOwnerDoesNotClose() {
        val negligent = GattOperationQueue<TestOperation, TestError>(
            timer,
            timeoutError = { TestError("OPERATIONTIMEDOUT", it) },
            onStall = { log += "stall ${it.name}" },
        )
        negligent.enqueue(TestOperation("a"))
        negligent.enqueue(TestOperation("b"))

        timer.advance(TIMEOUT_MS)
        negligent.enqueue(TestOperation("c"))

        // The queue closes itself with the timeout error: nothing waits forever.
        assertEquals(
            listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b OPERATIONTIMEDOUT", "fail c OPERATIONTIMEDOUT"),
            log,
        )
        assertTrue(negligent.isClosed)
    }

    @Test
    fun closeFromAnOperationsFailFailsTheWaitingOnesAndStartsNothing() {
        // As the platform code's close funnel does when an operation's failure takes the link down.
        val a = TestOperation("a", startError = TestError("OPERATIONSTARTFAILED", "refused"))
        a.onFail = { closeQueue() }
        val first = TestOperation("first")
        queue.enqueue(first)
        queue.enqueue(a)
        queue.enqueue(TestOperation("b"))
        queue.enqueue(TestOperation("c"))

        complete(first)
        timer.advance(TIMEOUT_MS * 2)

        assertEquals(
            listOf("start first", "done first", "start a", "fail a OPERATIONSTARTFAILED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"),
            log,
        )
        assertNull(queue.current)
    }

    @Test
    fun closeFromInsideADeliverFailsTheWaitingOnesAndStartsNothing() {
        val a = TestOperation("a")
        queue.enqueue(a)
        queue.enqueue(TestOperation("b"))

        queue.complete(a) {
            log += "done a"
            closeQueue()
        }
        timer.advance(TIMEOUT_MS * 2)

        assertEquals(listOf("start a", "done a", "fail b DEVICEDISCONNECTED"), log)
        assertNull(queue.current)
    }

    @Test
    fun eachOperationHasItsOwnTimeout() {
        val a = TestOperation("a", timeoutMs = 5_000)
        val b = TestOperation("b", timeoutMs = 1_000)
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(4_000)
        complete(a)
        timer.advance(999)
        assertEquals(listOf("start a", "done a", "start b"), log)
        timer.advance(1)

        assertEquals(listOf("start a", "done a", "start b", "stall b", "fail b OPERATIONTIMEDOUT"), log)
    }

    @Test
    fun operationThatSettlesOnTimeoutEndsItselfAndTheNextStarts() {
        val a = TestOperation("a", timeoutMs = 3_000, settlesOnTimeout = true)
        val b = TestOperation("b")
        queue.enqueue(a)
        queue.enqueue(b)

        timer.advance(3_000)

        assertEquals(listOf("start a", "settle a", "start b"), log)
        assertSame(b, queue.current)
        assertFalse(complete(a))
    }

    @Test
    fun closeFailsTheRunningAndEveryWaitingOperationInOrder() {
        queue.enqueue(TestOperation("a"))
        queue.enqueue(TestOperation("b"))
        queue.enqueue(TestOperation("c"))

        closeQueue()
        timer.advance(TIMEOUT_MS * 2)

        assertEquals(listOf("start a", "fail a DEVICEDISCONNECTED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"), log)
        assertNull(queue.current)
    }

    @Test
    fun closedQueueFailsEveryLaterOperationAtOnceWithTheFirstCloseError() {
        assertFalse(queue.isClosed)
        closeQueue()
        queue.close(TestError("BLUETOOTHMANAGERDESTROYED"))

        queue.enqueue(TestOperation("a"))

        assertEquals(listOf("fail a DEVICEDISCONNECTED"), log)
        assertNull(queue.current)
        assertTrue(queue.isClosed)
    }

    @Test
    fun eachFailureReportsItsCause() {
        val refused = TestOperation("refused", startError = TestError("OPERATIONSTARTFAILED", "refused"))
        val timedOut = TestOperation("timedOut")
        val waiting = TestOperation("waiting")
        val late = TestOperation("late")
        queue.enqueue(refused)
        queue.enqueue(timedOut)
        queue.enqueue(waiting)

        timer.advance(TIMEOUT_MS)
        queue.enqueue(late)

        assertEquals(listOf(FailCause.START_REFUSED), refused.causes)
        assertEquals(listOf(FailCause.TIMED_OUT), timedOut.causes)
        assertEquals(listOf(FailCause.QUEUE_CLOSED), waiting.causes)
        assertEquals(listOf(FailCause.QUEUE_CLOSED), late.causes)
    }

    @Test
    fun lateCompletionAfterCloseIsIgnored() {
        val a = TestOperation("a")
        queue.enqueue(a)
        closeQueue()

        assertFalse(complete(a))

        assertEquals(listOf("start a", "fail a DEVICEDISCONNECTED"), log)
    }

    // Exception safety (Kotlin only: Swift operations and owners can't throw).

    @Test
    fun throwingDeliverStillStartsTheNextOperation() {
        val a = TestOperation("a")
        queue.enqueue(a)
        queue.enqueue(TestOperation("b"))

        assertThrows(IllegalStateException::class.java) {
            queue.complete(a) { throw IllegalStateException("deliver threw") }
        }

        assertEquals(listOf("start a", "start b"), log)
    }

    @Test
    fun throwingStartFailureStillStartsTheNextOperation() {
        val a = TestOperation("a", startError = TestError("OPERATIONSTARTFAILED", "refused"))
        a.onFail = { throw IllegalStateException("fail of a threw") }

        val first = TestOperation("first")
        val b = TestOperation("b")
        queue.enqueue(first)
        queue.enqueue(a)
        queue.enqueue(b)

        assertThrows(IllegalStateException::class.java) { complete(first) }

        assertEquals(listOf("start first", "done first", "start a", "fail a OPERATIONSTARTFAILED", "start b"), log)
        assertSame(b, queue.current)
    }

    @Test
    fun throwingFailureStillFailsEveryOtherOperationOnClose() {
        val a = TestOperation("a").apply { onFail = { throw IllegalStateException("fail of a threw") } }
        val b = TestOperation("b").apply { onFail = { throw IllegalStateException("fail of b threw") } }
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(TestOperation("c"))

        val thrown = assertThrows(IllegalStateException::class.java) { closeQueue() }

        assertEquals(
            listOf("start a", "fail a DEVICEDISCONNECTED", "fail b DEVICEDISCONNECTED", "fail c DEVICEDISCONNECTED"),
            log,
        )
        assertEquals("fail of a threw", thrown.message)
        assertEquals("fail of b threw", thrown.suppressed.single().message)
    }

    @Test
    fun throwingOnStallStillFailsTheTimedOutOperationAndClosesTheQueue() {
        val throwing = GattOperationQueue<TestOperation, TestError>(
            timer,
            timeoutError = { TestError("OPERATIONTIMEDOUT", it) },
            onStall = { throw IllegalStateException("onStall threw") },
        )
        throwing.enqueue(TestOperation("a"))
        throwing.enqueue(TestOperation("b"))

        assertThrows(IllegalStateException::class.java) { timer.advance(TIMEOUT_MS) }

        assertEquals(listOf("start a", "fail a OPERATIONTIMEDOUT", "fail b OPERATIONTIMEDOUT"), log)
        assertTrue(throwing.isClosed)
    }

    @Test
    fun throwingSettleOnTimeoutStillStallsTheQueue() {
        val a = object : GattOperation<TestError> {
            override val description = "a"
            override val timeoutMs = TIMEOUT_MS

            override fun start(): TestError? = null.also { log += "start a" }

            override fun fail(error: TestError, cause: FailCause) {
                log += "fail a ${error.code}"
            }

            override fun settleOnTimeout(): Boolean = throw IllegalStateException("settle threw")
        }
        val stalls = GattOperationQueue<GattOperation<TestError>, TestError>(
            timer,
            timeoutError = { TestError("OPERATIONTIMEDOUT", it) },
            onStall = { log += "stall ${it.description}" },
        )
        stalls.enqueue(a)
        stalls.enqueue(TestOperation("b"))

        assertThrows(IllegalStateException::class.java) { timer.advance(TIMEOUT_MS) }

        assertEquals(listOf("start a", "stall a", "fail a OPERATIONTIMEDOUT", "fail b OPERATIONTIMEDOUT"), log)
    }

    private companion object {
        const val TIMEOUT_MS = 30_000L
    }
}
