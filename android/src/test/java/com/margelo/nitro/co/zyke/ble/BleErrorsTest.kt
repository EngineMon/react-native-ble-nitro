package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

/**
 * Unit tests for the code mappings of BleErrors.kt: the codes are part of the
 * contract (NativeBleNitro.nitro.ts), and iOS maps the same situations to the
 * same codes. The Android constants used are compile-time `int`s inlined by
 * the compiler, so these run on the plain JVM.
 */
class BleErrorsTest {
    private val characteristic: UUID = UUID.fromString("0000a001-0000-1000-8000-00805f9b34fb")

    @Test
    fun osRefusalMapsEachBluetoothStatusCodeAndKeepsTheStatus() {
        val cases = mapOf(
            BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION to BleErrorCode.BLUETOOTHUNAUTHORIZED,
            BLUETOOTH_STATUS_DEVICE_NOT_CONNECTED to BleErrorCode.DEVICENOTCONNECTED,
            BluetoothStatusCodes.ERROR_GATT_WRITE_NOT_ALLOWED to BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED,
            BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY to BleErrorCode.OPERATIONSTARTFAILED,
            BluetoothStatusCodes.ERROR_UNKNOWN to BleErrorCode.OPERATIONSTARTFAILED,
        )
        for ((status, code) in cases) {
            val error = osRefusalError("A CCCD write", status, notAllowedCode = BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED)
            assertEquals("status $status", code, error.code)
            assertEquals("status $status", status.toDouble(), error.nativeStatus)
        }
    }

    @Test
    fun writeNotAllowedIsTheWritesOwnFailure() {
        val error = osRefusalError("A write", BluetoothStatusCodes.ERROR_GATT_WRITE_NOT_ALLOWED, notAllowedCode = BleErrorCode.CHARACTERISTICWRITEFAILED)

        assertEquals(BleErrorCode.CHARACTERISTICWRITEFAILED, error.code)
    }

    @Test
    fun violationsGetTheOperationsOwnCodeWithoutStatus() {
        val cases = mapOf(
            GattRules.Violation.NotPermitted(GattRules.Access.Read) to BleErrorCode.CHARACTERISTICREADFAILED,
            GattRules.Violation.NotPermitted(GattRules.Access.Write(1, withResponse = true)) to BleErrorCode.CHARACTERISTICWRITEFAILED,
            GattRules.Violation.NotPermitted(GattRules.Access.Write(1, withResponse = false)) to BleErrorCode.CHARACTERISTICWRITEFAILED,
            GattRules.Violation.NotPermitted(GattRules.Access.Notify) to BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED,
            GattRules.Violation.TooLong(513, 512) to BleErrorCode.CHARACTERISTICWRITEFAILED,
        )
        for ((violation, code) in cases) {
            val error = violationError(violation, characteristic, "AA:BB:CC:DD:EE:FF")
            assertEquals("$violation", code, error.code)
            assertNull("$violation", error.nativeStatus)
        }
    }

    @Test
    fun failedCccdWriteIsNotifyChangeFailedWithTheGattStatus() {
        val error = cccdWriteError("Subscribing", 133)

        assertEquals(BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED, error.code)
        assertEquals(133.0, error.nativeStatus)
    }

    @Test
    fun linkEndsBeforeAndAfterConnectingKeepTheGattStatus() {
        val failed = connectionFailedError("AA:BB:CC:DD:EE:FF", 133)
        val lost = linkLostError("AA:BB:CC:DD:EE:FF", 8)

        assertEquals(BleErrorCode.DEVICECONNECTIONFAILED, failed.code)
        assertEquals(133.0, failed.nativeStatus)
        assertEquals(BleErrorCode.DEVICEDISCONNECTED, lost.code)
        assertEquals(8.0, lost.nativeStatus)
    }

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
