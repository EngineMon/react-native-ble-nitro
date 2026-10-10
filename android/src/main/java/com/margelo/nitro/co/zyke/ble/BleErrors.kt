package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import java.util.UUID

/*
 * The catalogue of every failure the manager reports: each BleError is built
 * here, by a builder named after the situation, and nowhere else (the
 * generic [bleError] is private to this file). iOS has the same catalogue
 * under the same names (ios/BleErrors.swift), so one situation gets the same
 * code and message on both platforms, and a change to one has an obvious
 * place on the other.
 *
 * The code numbers are react-native-ble-plx's (BleErrorCode), so code written
 * against it ports by name and number; which code a situation gets is this
 * library's contract (NativeBleNitro.nitro.ts), the same on Android and iOS.
 * nativeStatus carries the platform's own status (GATT/HCI status,
 * BluetoothStatusCodes value, scan error code) when Android gave one:
 * - a GATT procedure answered with a non-zero status: the procedure's failure
 *   code (CharacteristicReadFailed, CharacteristicWriteFailed,
 *   CharacteristicNotifyChangeFailed for a CCCD write, ...) + the status
 * - a request the characteristic can't take (its declared properties don't
 *   allow it, or a write is over the length limit): the operation's failure
 *   code without a status ([violationError]); nothing reaches the OS
 * - the OS refused to start a procedure: OperationStartFailed, or what the
 *   BluetoothStatusCodes value API 33+ returns says ([osRefusalError])
 * - no answer in time: OperationTimedOut
 * - a link that went down: DeviceDisconnected + the status
 * - a SecurityException (missing runtime permission): BluetoothUnauthorized
 * - scan refused or failed: ScanStartFailed + the scan error code, or the
 *   Bluetooth state / permission / location services code that explains it
 */

/** Builds a [BleError]; [nativeStatus] is the status Android reported, when it reported one. */
private fun bleError(code: BleErrorCode, message: String, nativeStatus: Int? = null): BleError =
    BleError(code, message, nativeStatus?.toDouble())

// Manager and adapter

internal fun destroyedError(): BleError =
    bleError(BleErrorCode.BLUETOOTHMANAGERDESTROYED, "The BLE manager was destroyed")

internal fun unsupportedError(): BleError =
    bleError(BleErrorCode.BLUETOOTHUNSUPPORTED, "This device has no Bluetooth adapter")

internal fun poweredOffError(action: String): BleError =
    bleError(BleErrorCode.BLUETOOTHPOWEREDOFF, "Cannot $action: Bluetooth is off")

/** Android threw a SecurityException: a runtime permission (e.g. BLUETOOTH_CONNECT/SCAN) is missing. */
internal fun unauthorizedError(operation: String, exception: SecurityException): BleError =
    bleError(BleErrorCode.BLUETOOTHUNAUTHORIZED, "$operation failed: a Bluetooth permission is missing (${exception.message})")

internal fun invalidIdentifiersError(vararg identifiers: String): BleError =
    bleError(BleErrorCode.INVALIDIDENTIFIERS, "Invalid identifiers: ${identifiers.joinToString()}")

/** requestBluetoothEnable without an activity in the foreground to ask the user from. */
internal fun noForegroundActivityError(): BleError =
    bleError(BleErrorCode.BLUETOOTHSTATECHANGEFAILED, "Cannot ask the user to turn Bluetooth on: the app has no activity in the foreground")

/** requestBluetoothEnable: no activity on the device handles BluetoothAdapter.ACTION_REQUEST_ENABLE. */
internal fun noEnableActivityError(): BleError =
    bleError(BleErrorCode.BLUETOOTHSTATECHANGEFAILED, "No activity handles the Bluetooth enable request")

/** requestBluetoothEnable: the user declined; [resultCode] is the activity result. */
internal fun enableDeclinedError(resultCode: Int): BleError =
    bleError(BleErrorCode.OPERATIONCANCELLED, "The user didn't turn Bluetooth on (activity result $resultCode)")

// Scanning

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

/** A running scan ended because Bluetooth turned off. */
internal fun scanStoppedByBluetoothOffError(): BleError =
    bleError(BleErrorCode.BLUETOOTHPOWEREDOFF, "The scan stopped: Bluetooth turned off")

internal fun scanPermissionMissingError(permission: String): BleError =
    bleError(BleErrorCode.BLUETOOTHUNAUTHORIZED, "Cannot scan: $permission is not granted")

internal fun locationServicesDisabledError(): BleError =
    bleError(
        BleErrorCode.LOCATIONSERVICESDISABLED,
        "Cannot scan: location services are off, and Android delivers no scan results to this app without them",
    )

/**
 * A scan start refused before reaching the OS by the scan-start budget
 * ([maxStarts] per [windowMs]); the next start fits in [waitMs].
 */
internal fun scanThrottledError(waitMs: Long, maxStarts: Int, windowMs: Long): BleError =
    bleError(
        BleErrorCode.SCANSTARTFAILED,
        "Cannot scan: Android allows $maxStarts scan starts per ${windowMs / 1000} s; retry in $waitMs ms",
    )

// Connecting and links

/** connect() while a connect to the device is still pending. */
internal fun alreadyConnectingError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICEALREADYCONNECTED, "A connection to $deviceId is already pending")

/** connect()'s timeoutMs is not a usable timeout (NaN, 0, negative, −∞). */
internal fun invalidConnectTimeoutError(deviceId: String, timeoutMs: Double?): BleError =
    bleError(BleErrorCode.OPERATIONSTARTFAILED, "Cannot connect to $deviceId: invalid timeoutMs $timeoutMs")

internal fun notConnectedError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICENOTCONNECTED, "Device $deviceId is not connected")

/** connectGatt returned no client. */
internal fun gattClientUnavailableError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICECONNECTIONFAILED, "Android could not create a GATT client for $deviceId")

/** The link went down before it was ever up; [status] is the GATT/HCI status (e.g. 133). */
internal fun connectionFailedError(deviceId: String, status: Int): BleError =
    bleError(BleErrorCode.DEVICECONNECTIONFAILED, "Connection to $deviceId failed (GATT status $status)", status)

internal fun connectTimedOutError(deviceId: String, timeoutMs: Long): BleError =
    bleError(BleErrorCode.OPERATIONTIMEDOUT, "Connection to $deviceId timed out after $timeoutMs ms")

/** A pending connect cancelled by disconnect(). */
internal fun connectCancelledError(deviceId: String): BleError =
    bleError(BleErrorCode.OPERATIONCANCELLED, "Connection to $deviceId was cancelled by disconnect()")

/** The link was lost; [status] is the GATT/HCI status Android reported. */
internal fun linkLostError(deviceId: String, status: Int): BleError =
    bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId disconnected (GATT status $status)", status)

/** The link was lost because Bluetooth turned off. */
internal fun bluetoothOffLinkLostError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId disconnected: Bluetooth turned off")

/** What the operations queued on a link get when disconnect() takes it down. */
internal fun disconnectingError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId is disconnecting")

/** The link ended after disconnect() (the OS reported it down, or the disconnect fallback closed it). */
internal fun disconnectedError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId was disconnected")

/** What the operations queued behind a timed-out one get when its timeout takes the link down. */
internal fun stalledLinkError(deviceId: String): BleError =
    bleError(BleErrorCode.DEVICEDISCONNECTED, "Device $deviceId was disconnected after an operation timed out")

/**
 * An operation timed out and took the link down: the reason the link's
 * subscriptions end with and its disconnect callback reports.
 */
internal fun stalledError(deviceId: String, operation: String, timeoutMs: Long): BleError =
    bleError(BleErrorCode.OPERATIONTIMEDOUT, "$operation timed out after $timeoutMs ms; the link to $deviceId was taken down")

/** The operation queue's timeout error ([GattOperationQueue]'s timeoutError factory); [message] names the operation and its timeout. */
internal fun operationTimedOutError(message: String): BleError =
    bleError(BleErrorCode.OPERATIONTIMEDOUT, message)

/** The notification hub's cancellation error ([NotificationHub]'s cancelledError factory): a Pending subscription removed by its owner. */
internal fun cancelledError(message: String): BleError =
    bleError(BleErrorCode.OPERATIONCANCELLED, message)

// The GATT database

/** No discovery of the current database succeeded on this link (none ran, one failed, or the services changed since). */
internal fun servicesNotDiscoveredError(deviceId: String): BleError =
    bleError(
        BleErrorCode.SERVICESNOTDISCOVERED,
        "The services of $deviceId are not discovered, or changed since they were; call discoverServices()",
    )

/** Service Changed: what the link's subscriptions end with. */
internal fun servicesChangedError(deviceId: String): BleError =
    bleError(BleErrorCode.SERVICESNOTDISCOVERED, "The services of $deviceId changed; discover them again")

/** The services changed while [operation] ran: its answer refers to the database that is gone. */
internal fun servicesChangedDuringError(deviceId: String, operation: String): BleError =
    bleError(BleErrorCode.SERVICESNOTDISCOVERED, "The services of $deviceId changed while '$operation' ran; discover them again")

/**
 * A discovery answered with GATT [status]: what the link's subscriptions end
 * with (Android no longer has the database they were made on).
 */
internal fun discoveryFailedSubscriptionsEndedError(deviceId: String, status: Int): BleError =
    bleError(
        BleErrorCode.SERVICESNOTDISCOVERED,
        "The service discovery on $deviceId failed (GATT status $status); Android no longer knows the subscribed characteristics",
        status,
    )

internal fun serviceNotFoundError(deviceId: String, service: UUID): BleError =
    bleError(BleErrorCode.SERVICENOTFOUND, "Service $service not found on $deviceId")

internal fun characteristicNotFoundError(deviceId: String, service: UUID, characteristic: UUID): BleError =
    bleError(BleErrorCode.CHARACTERISTICNOTFOUND, "Characteristic $characteristic not found in service $service on $deviceId")

// Operations

/** requestMTU with a value outside the integers 23...517. */
internal fun invalidMtuError(mtu: Double): BleError =
    bleError(
        BleErrorCode.DEVICEMTUCHANGEFAILED,
        "Invalid MTU $mtu: it must be an integer from ${GattRules.DEFAULT_ATT_MTU} to ${GattRules.MAX_ATT_MTU}",
    )

/** The OS refused to start [operation] without saying why (the GATT calls that return a boolean). */
internal fun startFailedError(operation: String): BleError =
    bleError(BleErrorCode.OPERATIONSTARTFAILED, "$operation could not be started")

/** [operation] threw [exception] when issued (other than a SecurityException: [unauthorizedError]). */
internal fun startThrewError(operation: String, exception: RuntimeException): BleError =
    startFailedError("$operation (${exception.javaClass.simpleName}: ${exception.message})")

/**
 * The value of BluetoothStatusCodes.ERROR_DEVICE_NOT_CONNECTED: the stack has
 * no connection to the device. BluetoothGatt lists it among the values
 * writeCharacteristic/writeDescriptor return
 * (BluetoothGatt.WriteOperationReturnValues), but the SDK hides the constant
 * itself (@hide), so it can't be referenced by name.
 */
internal const val BLUETOOTH_STATUS_DEVICE_NOT_CONNECTED = 4

/**
 * The OS refused to start [operation] and said why: [status] is the
 * BluetoothStatusCodes value that API 33+ BluetoothGatt.writeCharacteristic
 * and writeDescriptor return (every other GATT call returns only a boolean:
 * [startFailedError]). All of them are mapped here, in one place, so a
 * refusal means the same code wherever it happens, and the status always
 * stays in nativeStatus:
 * - ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION: BluetoothUnauthorized, the
 *   code of the SecurityException the other calls throw for the same reason.
 * - ERROR_DEVICE_NOT_CONNECTED: DeviceNotConnected; the stack has no
 *   connection to the device (the link went down before this manager heard
 *   of it).
 * - ERROR_GATT_WRITE_NOT_ALLOWED: the OS doesn't allow writing this attribute
 *   (no write property, or the stack restricts it), the write's own failure:
 *   [notAllowedCode], CharacteristicWriteFailed for a characteristic write,
 *   CharacteristicNotifyChangeFailed for a CCCD write (every CCCD failure of a
 *   subscription has that code).
 * - anything else (ERROR_GATT_WRITE_REQUEST_BUSY, ERROR_PROFILE_SERVICE_NOT_BOUND,
 *   ERROR_UNKNOWN, ...): OperationStartFailed.
 * The message names the status as a BluetoothStatusCodes value: it is not a
 * GATT status, and e.g. BUSY (201) has nothing to do with BleErrorCode 201.
 */
internal fun osRefusalError(operation: String, status: Int, notAllowedCode: BleErrorCode): BleError {
    val code = when (status) {
        BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION -> BleErrorCode.BLUETOOTHUNAUTHORIZED
        BLUETOOTH_STATUS_DEVICE_NOT_CONNECTED -> BleErrorCode.DEVICENOTCONNECTED
        BluetoothStatusCodes.ERROR_GATT_WRITE_NOT_ALLOWED -> notAllowedCode
        else -> BleErrorCode.OPERATIONSTARTFAILED
    }
    return bleError(code, "$operation was refused by Android (BluetoothStatusCodes $status)", status)
}

/** A GATT procedure the stack answered with a non-zero [status]; [code] is the procedure's failure code. */
internal fun gattStatusError(code: BleErrorCode, operation: String, status: Int): BleError =
    bleError(code, "$operation failed with GATT status $status", status)

/**
 * The CCCD (Client Characteristic Configuration descriptor) write of a
 * subscribe or unsubscribe was answered with a non-zero [status]:
 * CharacteristicNotifyChangeFailed, the code of every failed notification
 * change on both platforms (iOS reports the same failure through
 * didUpdateNotificationStateFor), not DescriptorWriteFailed: callers
 * subscribe and unsubscribe, they never write the descriptor themselves.
 */
internal fun cccdWriteError(operation: String, status: Int): BleError =
    gattStatusError(BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED, operation, status)

/** BluetoothGatt.setCharacteristicNotification refused to [enable] or disable the local notification registration. */
internal fun notificationRegistrationRefusedError(deviceId: String, characteristic: UUID, enable: Boolean): BleError =
    bleError(
        BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED,
        "Android refused to ${if (enable) "enable" else "disable"} notifications of $characteristic on $deviceId",
    )

/**
 * A request [GattRules] rejected before it reached the OS, for
 * [characteristic] of [deviceId]. The code is the operation's own failure
 * code (read 402; write, with or without response, and an over-long write
 * 401; subscribe 403), without nativeStatus, as there is no OS status.
 */
internal fun violationError(violation: GattRules.Violation, characteristic: UUID, deviceId: String): BleError = when (violation) {
    is GattRules.Violation.NotPermitted -> when (val access = violation.access) {
        GattRules.Access.Read -> bleError(
            BleErrorCode.CHARACTERISTICREADFAILED,
            "Characteristic $characteristic on $deviceId doesn't declare the read property",
        )
        is GattRules.Access.Write -> bleError(
            BleErrorCode.CHARACTERISTICWRITEFAILED,
            if (access.withResponse) {
                "Characteristic $characteristic on $deviceId doesn't declare the write property (write with response)"
            } else {
                "Characteristic $characteristic on $deviceId doesn't declare the writeWithoutResponse property"
            },
        )
        GattRules.Access.Notify -> bleError(
            BleErrorCode.CHARACTERISTICNOTIFYCHANGEFAILED,
            "Characteristic $characteristic on $deviceId supports neither notifications nor indications",
        )
    }
    is GattRules.Violation.TooLong -> bleError(
        BleErrorCode.CHARACTERISTICWRITEFAILED,
        "A write of ${violation.length} bytes to characteristic $characteristic on $deviceId is over its limit of ${violation.limit} bytes; nothing was sent",
    )
}

/** Maps a BluetoothAdapter state like ble-plx: the TURNING_* transitions are Resetting. */
internal fun adapterStateToBleState(adapterState: Int): BLEState = when (adapterState) {
    BluetoothAdapter.STATE_ON -> BLEState.POWEREDON
    BluetoothAdapter.STATE_OFF -> BLEState.POWEREDOFF
    BluetoothAdapter.STATE_TURNING_ON, BluetoothAdapter.STATE_TURNING_OFF -> BLEState.RESETTING
    else -> BLEState.UNKNOWN
}
