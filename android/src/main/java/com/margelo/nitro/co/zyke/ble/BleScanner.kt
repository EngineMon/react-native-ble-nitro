package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.os.Build
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import java.util.UUID
import java.util.concurrent.Executor

/**
 * One startScan call's callbacks, as the facade wrapped them (CallbackGate):
 * [onResult] for every reported advertisement while the scan runs; then at
 * most one of [startFailure] (the start failed: a completion of the call) or
 * [ended] (the running scan ended: the OS failed it or Bluetooth turned off;
 * an event). A scan that is stopped or replaced gets nothing more.
 */
internal class ScanCallbacks(
    val onResult: Listener<BLEDevice>,
    val startFailure: Failable<BleError>,
    val ended: Once<BleError>,
)

/**
 * The manager's one scan (NativeBleNitro.nitro.ts, startScan and stopScan).
 * - One scan at a time: a start that reaches the OS replaces the running scan,
 *   whose callbacks then get nothing more.
 * - A start that fails before reaching the OS (Bluetooth off, permission
 *   missing, location services off, Android's start throttle; the facade
 *   rejects invalid service UUIDs the same way) leaves the running scan alone
 *   and reports to the new call only: the caller asked for another scan and
 *   got none, which is no reason to lose the one it had.
 * - allowDuplicates false: each device is reported once per scan.
 * - rssiThreshold: weaker results are dropped; absent, nothing is.
 *
 * Confined to the manager's executor. [osEvents] brings the OS's scan
 * callbacks (main thread) onto it; [isLinkUp] tells whether the manager's link
 * to an address is up, for BLEDevice.isConnected.
 */
internal class BleScanner(
    private val osEvents: Executor,
    private val isLinkUp: (address: String) -> Boolean,
) {
    private var running: ActiveScan? = null

    val isScanning: Boolean
        get() = running != null

    fun start(bluetooth: Bluetooth, serviceUuids: List<UUID>, filter: ScanFilter, callbacks: ScanCallbacks) {
        val failure = startOrFail(bluetooth, serviceUuids, filter, callbacks)
        if (failure != null) callbacks.startFailure.fail(failure)
    }

    /** Starts the scan; returns why it didn't start, null when it runs. */
    private fun startOrFail(bluetooth: Bluetooth, serviceUuids: List<UUID>, filter: ScanFilter, callbacks: ScanCallbacks): BleError? {
        val adapter = bluetooth.adapter
        if (!adapter.isEnabled) return poweredOffError("scan")
        ScanPreconditions.check(bluetooth.context)?.let { return it }
        // Null while the adapter is not on.
        val scanner = adapter.bluetoothLeScanner ?: return poweredOffError("scan")
        val active = ActiveScan(adapter, filter, callbacks)
        val startInOs = {
            // From here on the start reaches the OS: the running scan is
            // replaced, whatever the outcome.
            stop()
            try {
                scanner.startScan(scanFilters(serviceUuids), scanSettings(filter.androidScanMode), active.osCallback)
                running = active
                null
            } catch (e: SecurityException) {
                unauthorizedError("Scanning", e)
            } catch (e: IllegalStateException) {
                // BluetoothLeScanner's answer when the adapter turned off since the check above.
                poweredOffError("scan")
            }
        }
        // The start throttle exists from Android 7.0 (API 24).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return startInOs()
        val throttle = ScanStartThrottle.process
        return throttle.tryStart(
            SystemClock.elapsedRealtime(),
            refused = { waitMs -> scanThrottledError(waitMs, throttle.maxStarts, throttle.windowMs) },
            start = startInOs,
        )
    }

    /** Stops the running scan; returns whether one was running. Calls no callback. */
    fun stop(): Boolean {
        val active = running ?: return false
        running = null
        // While the adapter is not on, the OS has stopped every scan already and
        // BluetoothLeScanner refuses calls.
        if (active.adapter.state != BluetoothAdapter.STATE_ON) return true
        try {
            active.adapter.bluetoothLeScanner?.stopScan(active.osCallback)
        } catch (e: IllegalStateException) {
            Log.i(TAG, "Bluetooth turned off while the scan stopped; the OS ended the scan itself")
        }
        return true
    }

    /**
     * Bluetooth is turning off: the OS stopped the scan already, and
     * BluetoothLeScanner refuses calls while the adapter isn't on. Forgets the
     * running scan without stopping it, and returns its end event, for the
     * caller to fire once every other state change of the same event is done
     * (a callback must see the links closed too).
     */
    fun abandon(): Once<BleError>? {
        val active = running ?: return null
        running = null
        return active.callbacks.ended
    }

    /** One startScan call; results of a stopped or replaced scan are recognized by identity and dropped. */
    private inner class ActiveScan(
        val adapter: BluetoothAdapter,
        private val filter: ScanFilter,
        val callbacks: ScanCallbacks,
    ) {
        private val reported = HashSet<String>()

        // The OS calls these on the main thread.
        val osCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                osEvents.execute { if (running === this@ActiveScan) onResult(result) }
            }

            override fun onScanFailed(errorCode: Int) {
                osEvents.execute {
                    if (running === this@ActiveScan) {
                        running = null
                        callbacks.ended.fire(scanFailedError(errorCode))
                    }
                }
            }
        }

        private fun onResult(result: ScanResult) {
            val threshold = filter.rssiThreshold
            if (threshold != null && result.rssi < threshold) return
            val address = result.device.address
            if (!filter.allowDuplicates && !reported.add(address)) return
            callbacks.onResult.emit(result.toBLEDevice(isConnected = isLinkUp(address)))
        }
    }

    private companion object {
        const val TAG = "BleNitro"
    }
}

private fun scanFilters(serviceUuids: List<UUID>): List<android.bluetooth.le.ScanFilter> =
    if (serviceUuids.isEmpty()) {
        // An empty filter matches every device.
        listOf(android.bluetooth.le.ScanFilter.Builder().build())
    } else {
        serviceUuids.map { android.bluetooth.le.ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build() }
    }

private fun scanSettings(mode: AndroidScanMode): ScanSettings = ScanSettings.Builder()
    .setScanMode(
        when (mode) {
            AndroidScanMode.LOWLATENCY -> ScanSettings.SCAN_MODE_LOW_LATENCY
            AndroidScanMode.LOWPOWER -> ScanSettings.SCAN_MODE_LOW_POWER
            AndroidScanMode.BALANCED -> ScanSettings.SCAN_MODE_BALANCED
            AndroidScanMode.OPPORTUNISTIC -> ScanSettings.SCAN_MODE_OPPORTUNISTIC
        }
    )
    // Every advertisement, each reported at once: duplicates are filtered here.
    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
    .setReportDelay(0)
    .build()
