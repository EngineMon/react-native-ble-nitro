package com.margelo.nitro.co.zyke.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** Unit tests for [ScanStartThrottle] (Android's 5 scan starts per 30 s). */
class ScanStartThrottleTest {
    private val throttle = ScanStartThrottle()

    /** Tries a start at [nowMs] whose OS start reports [osError]; returns "wait <ms>", the OS error, or null when it started. */
    private fun attempt(nowMs: Long, osError: String? = null): String? =
        throttle.tryStart(nowMs, refused = { wait -> "wait $wait" }) { osError }

    private fun startAt(nowMs: Long) = assertNull("start at $nowMs ms should be allowed", attempt(nowMs))

    @Test
    fun sixthStartWithinTheWindowWaitsForTheOldestToLeaveIt() {
        for (i in 0 until 5) startAt(i * 1_000L)

        assertEquals("wait 25000", attempt(5_000L))
    }

    @Test
    fun windowRollsWithEachRecordedStart() {
        for (i in 0 until 5) startAt(i * 1_000L)

        startAt(30_000L)

        // The oldest start is now the one at 1 s.
        assertEquals("wait 500", attempt(30_500L))
        startAt(31_000L)
    }

    @Test
    fun refusedStartDoesNotRunTheOsStartNorUseTheBudget() {
        for (i in 0 until 5) startAt(i * 1_000L)
        var ran = false

        throttle.tryStart(10_000L, refused = { "refused" }) { ran = true; null }

        assertFalse(ran)
        // Had the refused start been recorded, the window would still be full at 30 s.
        startAt(30_000L)
    }

    @Test
    fun startTheOsFailedDoesNotUseTheBudget() {
        for (i in 0 until 4) startAt(i * 1_000L)

        assertEquals("os refused", attempt(4_000L, osError = "os refused"))

        startAt(5_000L)
        assertEquals("wait 24000", attempt(6_000L))
    }
}
