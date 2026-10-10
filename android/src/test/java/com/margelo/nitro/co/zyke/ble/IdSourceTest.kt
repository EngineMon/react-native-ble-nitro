package com.margelo.nitro.co.zyke.ble

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unit tests for [IdSource]. Other tests may draw ids too, so these don't assume which id comes next. */
class IdSourceTest {
    @Test
    fun idsArePositiveAndIncreasing() {
        val first = IdSource.next()
        val second = IdSource.next()

        assertTrue(first > 0)
        assertTrue(second > first)
    }

    @Test
    fun idsAreUniqueAcrossThreads() {
        val ids = ConcurrentHashMap.newKeySet<Long>()
        val go = CountDownLatch(1)
        val threads = List(THREADS) {
            Thread {
                go.await()
                repeat(IDS_PER_THREAD) { ids += IdSource.next() }
            }
        }
        threads.forEach(Thread::start)

        go.countDown()
        threads.forEach(Thread::join)

        assertEquals(THREADS * IDS_PER_THREAD, ids.size)
    }

    private companion object {
        const val THREADS = 8
        const val IDS_PER_THREAD = 10_000
    }
}
