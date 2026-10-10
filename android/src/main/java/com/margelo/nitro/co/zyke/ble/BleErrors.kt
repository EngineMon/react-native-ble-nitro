package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback

/*
 * Every failure the manager reports is a BleError whose code is chosen the way
 * react-native-ble-plx's Android ErrorConverter chooses it, plus the platform's
 * own status (GATT/HCI status, scan error code) when Android gave one:
 * - a GATT procedure answered with a non-zero status: the procedure's failure
 *   code (CharacteristicReadFailed, DescriptorWriteFailed, ...) + the status
 * - the OS refused to start a procedure: OperationStartFailed
 * - no answer in time: OperationTimedOut
 * - a link that went down: DeviceDisconnected + the status
 * - a SecurityException (missing runtime permission): BluetoothUnauthorized
 * - scan refused or failed: ScanStartFailed + the scan error code, or the
 *   Bluetooth state / permission / location services code that explains it
 */

/** Builds a [BleError]; [nativeStatus] is the status Android reported, when it reported one. */
internal fun bleError(code: BleErrorCode, message: String, nativeStatus: Int? = null): BleError =
    BleError(code, message, nativeStatus?.toDouble())

internal fun destroyedError(): BleError =
    bleError(BleErrorCode.BLUETOOTHMANAGERDESTROYED, "The BLE manager was destroyed")

internal fun notConnectedError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICENOTCONNECTED, "Device $deviceId is not connected")

internal fun unsupportedError(): BleError =
    bleError(BleErrorCode.BLUETOOTHUNSUPPORTED, "This device has no Bluetooth adapter")

internal fun poweredOffError(action: String): BleError =
    bleError(BleErrorCode.BLUETOOTHPOWEREDOFF, "Cannot $action: Bluetooth is off")

/** Android threw a SecurityException: a runtime permission (e.g. BLUETOOTH_CONNECT/SCAN) is missing. */
internal fun unauthorizedError(operation: String, exception: SecurityException): BleError =
    bleError(BleErrorCode.BLUETOOTHUNAUTHORIZED, "$operation failed: a Bluetooth permission is missing (${exception.message})")

internal fun invalidIdentifiersError(vararg identifiers: String): BleError =
    bleError(BleErrorCode.INVALIDIDENTIFIERS, "Invalid identifiers: ${identifiers.joinToString()}")

/** The OS refused to start [operation]; [status] is the BluetoothStatusCodes value API 33+ returns. */
internal fun startFailedError(operation: String, status: Int? = null): BleError =
    bleError(
        BleErrorCode.OPERATIONSTARTFAILED,
        if (status == null) "$operation could not be started" else "$operation could not be started (status $status)",
        status,
    )

/** A GATT procedure the stack answered with a non-zero [status]. */
internal fun gattStatusError(code: BleErrorCode, operation: String, status: Int): BleError =
    bleError(code, "$operation failed with GATT status $status", status)

/** [ScanCallback.onScanFailed] reported [errorCode]. */
internal fun scanFailedError(errorCode: Int): BleError {
    val reason = when (errorCode) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "a scan with this callback is already running"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "the app could not be registered for scanning"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "internal error"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "the scan settings are not supported by this device"
        ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES -> "out of hardware resources"
        ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY -> "scanning too frequently"
        else -> "error code $errorCode"
    }
    return bleError(BleErrorCode.SCANSTARTFAILED, "Scan failed: $reason", errorCode)
}

/** Maps a BluetoothAdapter state like ble-plx: the TURNING_* transitions are Resetting. */
internal fun adapterStateToBleState(adapterState: Int): BLEState = when (adapterState) {
    BluetoothAdapter.STATE_ON -> BLEState.POWEREDON
    BluetoothAdapter.STATE_OFF -> BLEState.POWEREDOFF
    BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> BLEState.RESETTING
    else -> BLEState.UNKNOWN
}
