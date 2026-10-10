package com.margelo.nitro.co.zyke.ble

import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unit tests for [Reply], [Once] and [Listener]: at most once, released after use, and a throwing user callback never escapes. */
class CallbacksTest {
    private val logs = CoreLogCapture()
    private val timedOut = TestError("OPERATIONTIMEDOUT", "timed out")

    @After
    fun stopCapturing() = logs.close()

    @Test
    fun replyDeliversOnlyTheFirstCompletion() {
        val delivered = mutableListOf<String>()
        val reply = Reply<Int, TestError> { error, value -> delivered += "${error?.code} $value" }

        reply.fail(timedOut)
        reply.succeed(1)
        reply.fail(timedOut)

        assertEquals(listOf("OPERATIONTIMEDOUT null"), delivered)
        assertTrue(logs.records.isNotEmpty())
    }

    @Test
    fun replyIsCompletedOnceEvenWhenThreadsRace() {
        val deliveries = AtomicInteger()
        val reply = Reply<Int, TestError> { _, _ -> deliveries.incrementAndGet() }
        val go = CountDownLatch(1)
        val threads = List(8) { n ->
            Thread {
                go.await()
                reply.succeed(n)
            }
        }
        threads.forEach(Thread::start)

        go.countDown()
        threads.forEach(Thread::join)

        assertEquals(1, deliveries.get())
    }

    @Test
    fun replyReleasesItsCallbackWhenItCompletes() {
        val (reply, captured) = holding { held -> Reply<Unit, TestError> { _, _ -> held.hashCode() } }
        assertNotNull(captured.get())

        reply.succeed()

        // What the callback held (a JS function, a C++ closure) doesn't outlive
        // the completion, even though the operation holding the Reply may.
        assertTrue(collected(captured))
        assertNotNull(reply)
    }

    @Test
    fun onceFiresOnlyTheFirstTime() {
        val fired = mutableListOf<Int>()
        val once = Once<Int> { fired += it }

        once.fire(1)
        once.fire(2)

        assertEquals(listOf(1), fired)
        assertTrue(logs.records.isNotEmpty())
    }

    @Test
    fun onceReleasesItsCallbackWhenItFires() {
        val (once, captured) = holding { held -> Once<Int> { held.hashCode() } }
        assertNotNull(captured.get())

        once.fire(1)

        assertTrue(collected(captured))
        assertNotNull(once)
    }

    /**
     * Builds a wrapper with [build] around a callback that holds a new object,
     * and a weak reference to that object. The object is created outside the
     * test's frame, so only the wrapper's callback keeps it reachable.
     */
    private fun <W> holding(build: (held: Any) -> W): Pair<W, WeakReference<Any>> {
        val held = Any()
        return build(held) to WeakReference(held)
    }

    @Test
    fun replyThatThrewStillCountsAsCompletedAndTheThrowIsLogged() {
        var calls = 0
        val reply = Reply<Unit, TestError> { _, _ ->
            calls++
            throw IllegalStateException("thrown by a C++ callback")
        }

        reply.succeed()
        reply.succeed()

        assertEquals(1, calls)
        assertTrue(logs.records.any { it.thrown?.message == "thrown by a C++ callback" })
    }

    @Test
    fun everyThrowableIsCaughtNotOnlyExceptions() {
        Reply<Unit, TestError> { _, _ -> throw StackOverflowError("deep") }.succeed()
        Once<Int> { throw AssertionError("asserted") }.fire(1)
        Listener<Int> { throw OutOfMemoryError("full") }.emit(1)

        assertEquals(listOf("deep", "asserted", "full"), logs.records.mapNotNull { it.thrown?.message })
    }

    @Test
    fun listenerKeepsEmittingAfterItsCallbackThrew() {
        val emitted = mutableListOf<Int>()
        val listener = Listener<Int> {
            emitted += it
            if (it == 1) throw IllegalStateException("first value rejected")
        }

        listener.emit(1)
        listener.emit(2)

        assertEquals(listOf(1, 2), emitted)
    }
}
