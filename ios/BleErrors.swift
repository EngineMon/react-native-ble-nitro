import Foundation
import CoreBluetooth
import NitroModules

/*
 * The catalogue of every failure the manager reports: each BleError is built here, by a
 * builder named after the situation, and nowhere else (the two BleError initializers
 * below are private to this file). Android has the same catalogue under the same names
 * (android/.../BleErrors.kt), so one situation gets the same code and message on both
 * platforms, and a change to one has an obvious place on the other. Builders exist on
 * one side only where the situation does (iOS: characteristics not discovered, device
 * not found, the CoreBluetooth states; Android: OS refusals, permissions, the scan
 * throttle).
 *
 * The code numbers are react-native-ble-plx's (BleErrorCode), so code written against it
 * ports by name and number; which code a situation gets is this library's contract
 * (NativeBleNitro.nitro.ts), the same on Android and iOS. nativeStatus carries
 * CoreBluetooth's own status when it gave one: the code of its CBError or CBATTError
 * (see `BleError.init(_:_:cause:)`).
 * - a GATT procedure CoreBluetooth answered with an error: the procedure's failure code
 *   (CharacteristicReadFailed, CharacteristicWriteFailed, CharacteristicNotifyChangeFailed
 *   for a CCCD write, ...) + the status (`gattStatusError`)
 * - a request the characteristic can't take (its declared properties don't allow it, or
 *   a write is over the length limit): the operation's failure code without a status
 *   (`violationError`); nothing reaches the OS
 * - no answer in time: OperationTimedOut
 * - a link that went down: DeviceDisconnected + the status
 */

extension BleError {
    /// A failure this module detected itself; there is no platform status.
    fileprivate init(_ code: BleErrorCode, _ message: String) {
        self.init(code: code, message: message, nativeStatus: nil)
    }

    /**
     * A failure CoreBluetooth reported through `cause`. `code` names what failed and the
     * platform error adds the detail: `nativeStatus` is its CBError or CBATTError code
     * (the two domains' numbers overlap; the message names the domain). It is absent when
     * CoreBluetooth gave no error, or one from another domain.
     */
    fileprivate init(_ code: BleErrorCode, _ message: String, cause: Error?) {
        guard let cause else {
            self.init(code, message)
            return
        }
        let error = cause as NSError
        let isCoreBluetooth = error.domain == CBErrorDomain || error.domain == CBATTErrorDomain
        self.init(
            code: code,
            message: "\(message): \(error.domain) \(error.code) (\(error.localizedDescription))",
            nativeStatus: isCoreBluetooth ? Double(error.code) : nil
        )
    }
}

// MARK: - Manager and Bluetooth state

/**
 * What every completion reports once the manager was destroyed (NativeBleNitro.nitro.ts,
 * "After destroy()"), also a call that was waiting when destroy() ran.
 */
func destroyedError() -> BleError {
    return BleError(.bluetoothmanagerdestroyed, "The BLE manager was destroyed")
}

/**
 * Why a request that needs Bluetooth on can't run in `state`; nil when it is on. The
 * codes are ble-plx's (RxBluetoothKit's `BluetoothError(state:)`): poweredOff 102,
 * unauthorized 101, unsupported 100, resetting 103, unknown 104. A request made while the
 * state is still `.unknown` waits for the first real state instead of failing (see
 * PoweredOnWaiters); `.unknown` maps to an error only for what was running when the state
 * fell back to it.
 */
func unavailableError(_ state: CBManagerState) -> BleError? {
    switch state {
    case .poweredOn: return nil
    case .poweredOff: return BleError(.bluetoothpoweredoff, "Bluetooth is turned off")
    case .unauthorized: return BleError(.bluetoothunauthorized, "Bluetooth use is not authorized")
    case .unsupported: return BleError(.bluetoothunsupported, "Bluetooth LE is not supported")
    case .resetting: return BleError(.bluetoothresetting, "Bluetooth is resetting")
    case .unknown: return BleError(.bluetoothinunknownstate, "Bluetooth state is not known yet")
    @unknown default: return BleError(.bluetoothinunknownstate, "Bluetooth is in unknown state \(state.rawValue)")
    }
}

/// requestBluetoothEnable: iOS has no API that turns Bluetooth on or asks the user to.
func bluetoothStateChangeFailedError() -> BleError {
    return BleError(.bluetoothstatechangefailed, "iOS does not let apps turn Bluetooth on")
}

/// A device id or UUID that doesn't parse (NativeBleNitro.nitro.ts: InvalidIdentifiers comes first of all checks).
func invalidIdentifiersError(_ identifiers: String...) -> BleError {
    return BleError(.invalididentifiers, "Invalid identifiers: \(identifiers.joined(separator: ", "))")
}

// MARK: - Connecting and links

/// connect() to a peripheral this manager neither saw in a scan nor can retrieve from the system.
func deviceNotFoundError(_ deviceId: String) -> BleError {
    return BleError(.devicenotfound, "Device \(deviceId) not found")
}

/// connect() while a connect to the device is still pending.
func alreadyConnectingError(_ deviceId: String) -> BleError {
    return BleError(.devicealreadyconnected, "A connection to \(deviceId) is already pending")
}

/// connect()'s timeoutMs is not a usable timeout (NaN, 0, negative, −∞; see GattRules.connectDeadline).
func invalidConnectTimeoutError(deviceId: String, timeoutMs: Double?) -> BleError {
    let value = timeoutMs.map { "\($0)" } ?? "nil"
    return BleError(.operationstartfailed, "Cannot connect to \(deviceId): invalid timeoutMs \(value)")
}

/// No link of this manager to `deviceId` is up.
func notConnectedError(_ deviceId: String) -> BleError {
    return BleError(.devicenotconnected, "Device \(deviceId) is not connected")
}

/**
 * The attempt ended before the link was up: didFailToConnect, or a didDisconnectPeripheral
 * of the attempt itself. `cause` is CoreBluetooth's error.
 */
func connectionFailedError(_ deviceId: String, cause: Error?) -> BleError {
    return BleError(.deviceconnectionfailed, "Connection to \(deviceId) failed", cause: cause)
}

func connectTimedOutError(_ deviceId: String, timeoutMs: Int) -> BleError {
    return BleError(.operationtimedout, "Connection to \(deviceId) timed out after \(timeoutMs) ms")
}

/// A pending connect cancelled by disconnect().
func connectCancelledError(_ deviceId: String) -> BleError {
    return BleError(.operationcancelled, "Connection to \(deviceId) was cancelled by disconnect()")
}

/// The link was lost; `cause` is the error didDisconnectPeripheral reported.
func linkLostError(_ deviceId: String, cause: Error?) -> BleError {
    return BleError(.devicedisconnected, "Device \(deviceId) disconnected", cause: cause)
}

/**
 * The link was lost because Bluetooth left the powered-on state (`unavailable` is that
 * state's error, see `unavailableError`). Android's builder of the same name covers only
 * Bluetooth turning off, its one such state.
 */
func bluetoothOffLinkLostError(_ deviceId: String, _ unavailable: BleError) -> BleError {
    return BleError(.devicedisconnected, "Device \(deviceId) disconnected: \(unavailable.message)")
}

/// What the operations queued on a link get when disconnect() takes it down.
func disconnectingError(_ deviceId: String) -> BleError {
    return BleError(.devicedisconnected, "Device \(deviceId) is disconnecting")
}

/// The link ended after disconnect() (didDisconnectPeripheral reported it down).
func disconnectedError(_ deviceId: String) -> BleError {
    return BleError(.devicedisconnected, "Device \(deviceId) was disconnected")
}

/// What the operations queued behind a timed-out one get when its timeout takes the link down.
func stalledLinkError(_ deviceId: String) -> BleError {
    return BleError(.devicedisconnected, "Device \(deviceId) was disconnected after an operation timed out")
}

/**
 * An operation timed out and took the link down: the reason the link's subscriptions end
 * with and its disconnect callback reports.
 */
func stalledError(_ deviceId: String, operation: String, timeoutMs: Int) -> BleError {
    return BleError(.operationtimedout, "\(operation) timed out after \(timeoutMs) ms; the link to \(deviceId) was taken down")
}

/// The operation queue's timeout error (GattOperationQueue's timeoutError factory); `message` names the operation and its timeout.
func operationTimedOutError(_ message: String) -> BleError {
    return BleError(.operationtimedout, message)
}

/// The notification hub's cancellation error (NotificationHub's cancelledError factory): a Pending subscription removed by its owner.
func cancelledError(_ message: String) -> BleError {
    return BleError(.operationcancelled, message)
}

// MARK: - The GATT database

/// No discovery of the current database succeeded on this link (none ran, or the services changed since).
func servicesNotDiscoveredError(_ deviceId: String) -> BleError {
    return BleError(
        .servicesnotdiscovered,
        "The services of \(deviceId) are not discovered, or changed since they were; call discoverServices()"
    )
}

/// Service Changed: what the subscriptions of the changed services end with, and the request in flight on one of them fails with.
func servicesChangedError(_ deviceId: String) -> BleError {
    return BleError(.servicesnotdiscovered, "The services of \(deviceId) changed; discover them again")
}

/// The services changed while `operation` ran: its answer refers to the database that is gone.
func servicesChangedDuringError(_ deviceId: String, operation: String) -> BleError {
    return BleError(.servicesnotdiscovered, "The services of \(deviceId) changed while '\(operation)' ran; discover them again")
}

func serviceNotFoundError(_ deviceId: String, service: CBUUID) -> BleError {
    return BleError(.servicenotfound, "Service \(service.fullUUIDString) not found on \(deviceId)")
}

/**
 * The service is discovered but its characteristics aren't. iOS only: CoreBluetooth
 * discovers characteristics per service, and a service CoreBluetooth reports with
 * `characteristics` nil was never asked (Android discovers both in one procedure).
 */
func characteristicsNotDiscoveredError(_ deviceId: String, service: CBUUID) -> BleError {
    return BleError(
        .characteristicsnotdiscovered,
        "The characteristics of service \(service.fullUUIDString) on \(deviceId) are not discovered; call discoverServices()"
    )
}

func characteristicNotFoundError(_ deviceId: String, service: CBUUID, characteristic: CBUUID) -> BleError {
    return BleError(
        .characteristicnotfound,
        "Characteristic \(characteristic.fullUUIDString) not found in service \(service.fullUUIDString) on \(deviceId)"
    )
}

// MARK: - Operations

/// requestMTU with a value outside the integers 23...517 (GattRules.validMtuRequest).
func invalidMtuError(_ mtu: Double) -> BleError {
    return BleError(
        .devicemtuchangefailed,
        "Invalid MTU \(mtu): it must be an integer from \(GattRules.defaultAttMtu) to \(GattRules.maxAttMtu)"
    )
}

/**
 * CoreBluetooth answered `operation` with `cause` (CBATTError for an ATT error response,
 * CBError otherwise); `code` is the procedure's failure code (SessionOperation.answer).
 * `cause` nil: CoreBluetooth reported success without the result the procedure needs
 * (e.g. a read without a value).
 *
 * A CCCD (Client Characteristic Configuration descriptor) write of a subscribe or
 * unsubscribe that failed (didUpdateNotificationStateFor with an error) gets
 * CharacteristicNotifyChangeFailed, the code of every failed notification change on both
 * platforms (Android's cccdWriteError), not DescriptorWriteFailed: callers subscribe and
 * unsubscribe, they never write the descriptor themselves.
 */
func gattStatusError(_ code: BleErrorCode, _ operation: String, cause: Error?) -> BleError {
    return BleError(code, "\(operation) failed", cause: cause)
}

/**
 * The CCCD write reported no error, but the characteristic's notifying state isn't the
 * one written (`notifying` is the state it kept). iOS only: CoreBluetooth reports the
 * result as the characteristic's `isNotifying`.
 */
func cccdStateMismatchError(_ operation: String, notifying: Bool) -> BleError {
    return BleError(.characteristicnotifychangefailed, "\(operation) failed: notifications are still \(notifying ? "on" : "off")")
}

/**
 * A request GattRules rejected before it reached the OS, for `characteristic` of
 * `deviceId`. The code is the operation's own failure code (read 402; write, with or
 * without response, and an over-long write 401; subscribe 403), without nativeStatus, as
 * there is no OS status.
 */
func violationError(_ violation: GattRules.Violation, characteristic: CBUUID, deviceId: String) -> BleError {
    let name = characteristic.fullUUIDString
    switch violation {
    case .notPermitted(.read):
        return BleError(.characteristicreadfailed, "Characteristic \(name) on \(deviceId) doesn't declare the read property")
    case .notPermitted(.write(_, let withResponse)):
        let property = withResponse ? "write property (write with response)" : "writeWithoutResponse property"
        return BleError(.characteristicwritefailed, "Characteristic \(name) on \(deviceId) doesn't declare the \(property)")
    case .notPermitted(.notify):
        return BleError(.characteristicnotifychangefailed, "Characteristic \(name) on \(deviceId) supports neither notifications nor indications")
    case .tooLong(let length, let limit):
        return BleError(
            .characteristicwritefailed,
            "A write of \(length) bytes to characteristic \(name) on \(deviceId) is over its limit of \(limit) bytes; nothing was sent"
        )
    }
}
