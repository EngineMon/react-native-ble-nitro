package com.margelo.nitro.co.zyke.ble

/**
 * Android 7.0+ silently ignores a scan start when the app already started
 * [maxStarts] scans within the last [windowMs]: the scan "runs" but never
 * reports a result. Like RxAndroidBle (ScanPreconditionsVerifierApi24), the
 * manager tracks its own starts and fails such a scan with ScanStartFailed
 * instead, so the caller learns why nothing arrives and when to retry.
 *
 * Times are monotonic milliseconds (SystemClock.elapsedRealtime in the app).
 * Not thread-safe: used on the manager's handler thread only.
 */
internal class ScanStartThrottle(
    private val maxStarts: Int = 5,
    private val windowMs: Long = 30_000L,
) {
    /** Start times of the latest scans, oldest at [oldest] once [recorded] reached [maxStarts]. */
    private val starts = LongArray(maxStarts)
    private var recorded = 0
    private var oldest = 0

    /** Milliseconds until the OS accepts another scan start, 0 when it accepts one at [nowMs]. */
    fun delayBeforeNextStart(nowMs: Long): Long {
        if (recorded < maxStarts) return 0
        return (starts[oldest] + windowMs - nowMs).coerceAtLeast(0)
    }

    /** Records a scan started at [nowMs]. */
    fun recordStart(nowMs: Long) {
        if (recorded < maxStarts) {
            starts[recorded++] = nowMs
        } else {
            starts[oldest] = nowMs
            oldest = (oldest + 1) % maxStarts
        }
    }
}
