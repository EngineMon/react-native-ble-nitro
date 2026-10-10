package com.margelo.nitro.co.zyke.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/** Unit tests for [ScanStartThrottle] (Android's 5 scan starts per 30 s). */
class ScanStartThrottleTest {
    private val throttle = ScanStartThrottle()

    private fun startAt(nowMs: Long) {
        assertEquals("start at $nowMs ms should be allowed", 0L, throttle.delayBeforeNextStart(nowMs))
        throttle.recordStart(nowMs)
    }

    @Test
    fun sixthStartWithinTheWindowWaitsForTheOldestToLeaveIt() {
        for (i in 0 until 5) startAt(i * 1_000L)

        assertEquals(25_000L, throttle.delayBeforeNextStart(5_000L))
    }

    @Test
    fun windowRollsWithEachRecordedStart() {
        for (i in 0 until 5) startAt(i * 1_000L)

        startAt(30_000L)

        // The oldest start is now the one at 1 s.
        assertEquals(500L, throttle.delayBeforeNextStart(30_500L))
        assertEquals(0L, throttle.delayBeforeNextStart(31_000L))
    }

    @Test
    fun refusedStartsDoNotCount() {
        for (i in 0 until 5) startAt(i * 1_000L)
        // Asked but refused: nothing recorded.
        throttle.delayBeforeNextStart(10_000L)

        assertEquals(0L, throttle.delayBeforeNextStart(30_000L))
    }
}
