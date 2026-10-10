package com.margelo.nitro.co.zyke.ble

/**
 * Android 7.0+ silently ignores a scan start when the app already started
 * [maxStarts] scans within the last [windowMs]: the scan "runs" but never
 * reports a result. The manager tracks the starts and fails such a scan with
 * ScanStartFailed instead, so the caller learns why nothing arrives and when
 * to retry.
 *
 * Android counts the starts per app, not per scanner client: every manager of
 * the process (several at once, or the ones a JS reload left behind until
 * their teardown ran) draws from one budget. They therefore all use the one
 * [process] instance; a throttle per manager would undercount, report a start
 * as accepted that the OS then ignores, and defeat its own purpose.
 *
 * [tryStart] is the only entry point: it checks the budget, runs the start and
 * records it under one lock, so two managers on their own threads can't both
 * take the last free slot, and no caller can check without recording or
 * record without checking.
 *
 * Times are monotonic milliseconds (SystemClock.elapsedRealtime in the app).
 */
internal class ScanStartThrottle(
    val maxStarts: Int = 5,
    val windowMs: Long = 30_000L,
) {
    /** Start times of the latest scans, oldest at [oldest] once [recorded] reached [maxStarts]. */
    private val starts = LongArray(maxStarts)
    private var recorded = 0
    private var oldest = 0

    /**
     * Runs [start] at [nowMs] when the budget allows another start, and
     * records it when [start] reports no error (a start the OS refused uses
     * none of the budget). When the budget is used up, [start] doesn't run and
     * the result is [refused] with the milliseconds until a start is allowed.
     * Returns the error to report, null when the scan started.
     */
    @Synchronized
    fun <E : Any> tryStart(nowMs: Long, refused: (waitMs: Long) -> E, start: () -> E?): E? {
        val wait = if (recorded < maxStarts) 0L else (starts[oldest] + windowMs - nowMs).coerceAtLeast(0)
        if (wait > 0) return refused(wait)
        val error = start()
        if (error == null) record(nowMs)
        return error
    }

    private fun record(nowMs: Long) {
        if (recorded < maxStarts) {
            starts[recorded++] = nowMs
        } else {
            starts[oldest] = nowMs
            oldest = (oldest + 1) % maxStarts
        }
    }

    companion object {
        /** The app's scan-start budget, shared by every manager of the process. */
        val process = ScanStartThrottle()
    }
}
