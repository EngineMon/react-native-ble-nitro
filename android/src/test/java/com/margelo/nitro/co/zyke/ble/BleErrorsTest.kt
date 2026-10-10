package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for the ble-plx-compatible mappings in BleErrors.kt. The Android
 * constants used are compile-time `int`s inlined by the compiler, so these run
 * on the plain JVM.
 */
class BleErrorsTest {
    @Test
    fun adapterTransitionsAreResetting() {
        assertEquals(BLEState.RESETTING, adapterStateToBleState(BluetoothAdapter.STATE_TURNING_ON))
        assertEquals(BLEState.RESETTING, adapterStateToBleState(BluetoothAdapter.STATE_TURNING_OFF))
    }

    @Test
    fun adapterOnAndOffMapToPoweredOnAndOff() {
        assertEquals(BLEState.POWEREDON, adapterStateToBleState(BluetoothAdapter.STATE_ON))
        assertEquals(BLEState.POWEREDOFF, adapterStateToBleState(BluetoothAdapter.STATE_OFF))
    }

    @Test
    fun scanFailureIsScanStartFailedWithTheOsErrorCode() {
        val error = scanFailedError(ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED)

        assertEquals(BleErrorCode.SCANSTARTFAILED, error.code)
        assertEquals(ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED.toDouble(), error.nativeStatus)
    }
}
