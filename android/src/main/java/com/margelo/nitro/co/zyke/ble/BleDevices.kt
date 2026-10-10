package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanResult
import android.os.Build
import android.util.Log
import com.margelo.nitro.core.ArrayBuffer
import java.util.UUID

/*
 * The BLEDevice values the manager reports, and the service filter of
 * getConnectedDevices.
 */

private const val TAG = "BleNitro"

/** HCI "RSSI not available": the RSSI of a device known without an advertisement (iOS reports the same). */
private const val RSSI_UNAVAILABLE = 127.0

/**
 * getConnectedDevices' `services` argument, with its two meanings as types,
 * so an empty list can't be mistaken for "no filter" or the other way round.
 */
internal sealed interface ServiceFilter {
    /** `services` was empty: every link of this manager, and the devices the OS is connected to. */
    data object Any : ServiceFilter

    /**
     * `services` named services: the links whose discovered services include
     * one of [uuids]. Empty when none of the names parsed; it then matches
     * nothing (a name that doesn't parse can't name a discovered service).
     */
    data class AnyOf(val uuids: List<UUID>) : ServiceFilter
}

/** A connected device: no advertisement, so no RSSI, advertised data or name beyond the cached one. */
internal fun connectedDevice(device: BluetoothDevice, isConnected: Boolean) = BLEDevice(
    id = device.address,
    name = cachedName(device) ?: "",
    rssi = RSSI_UNAVAILABLE,
    manufacturerData = ManufacturerData(companyIdentifiers = emptyArray()),
    serviceData = ServiceData(services = emptyArray()),
    serviceUUIDs = emptyArray(),
    isConnectable = true,
    isConnected = isConnected,
)

/** A scan result; [isConnected]: this manager's link to the device is up (a device may keep advertising while connected). */
internal fun ScanResult.toBLEDevice(isConnected: Boolean): BLEDevice {
    val record = scanRecord
    val manufacturerData = record?.manufacturerSpecificData
    val manufacturerEntries = if (manufacturerData == null) {
        emptyArray()
    } else {
        // Company identifier (decimal) and the payload after it.
        Array(manufacturerData.size()) { i ->
            ManufacturerDataEntry(id = manufacturerData.keyAt(i).toString(), data = ArrayBuffer.copy(manufacturerData.valueAt(i)))
        }
    }
    val serviceEntries = record?.serviceData?.map { (uuid, data) ->
        ServiceDataEntry(uuid = uuid.toString(), data = ArrayBuffer.copy(data))
    }?.toTypedArray() ?: emptyArray()
    return BLEDevice(
        id = device.address,
        // The Local Name the device advertises now (Bluetooth Core Specification
        // Supplement Part A §1.2), like iOS's CBAdvertisementDataLocalNameKey.
        // BluetoothDevice.getName() is only the fallback: it is the name the
        // stack cached, stale or absent for a device that renamed itself or
        // was never queried; it needs BLUETOOTH_CONNECT from API 31; and it is
        // a binder call, too costly for every advertisement.
        name = record?.deviceName ?: cachedName(device) ?: "",
        rssi = rssi.toDouble(),
        manufacturerData = ManufacturerData(companyIdentifiers = manufacturerEntries),
        serviceData = ServiceData(services = serviceEntries),
        serviceUUIDs = record?.serviceUuids?.map { it.toString() }?.toTypedArray() ?: emptyArray(),
        // Before API 26 Android doesn't tell; legacy advertisements are mostly connectable.
        isConnectable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) isConnectable else true,
        isConnected = isConnected,
    )
}

/**
 * The devices the OS has a GATT connection to (any app's). Needs
 * BLUETOOTH_CONNECT on API 31+; without it they are left out and the reason
 * is logged (getConnectedDevices never throws).
 */
internal fun osGattConnectedDevices(manager: BluetoothManager): List<BluetoothDevice> = try {
    manager.getConnectedDevices(BluetoothProfile.GATT)
} catch (e: SecurityException) {
    Log.w(TAG, "getConnectedDevices leaves out the devices the OS is connected to: BLUETOOTH_CONNECT is not granted (${e.message})")
    emptyList()
}

/**
 * BluetoothDevice.getName(), the stack's cached name; null when unknown or
 * without BLUETOOTH_CONNECT (API 31+). The SecurityException is not logged:
 * this runs for every advertisement of a device without an advertised name,
 * and a missing name is a normal outcome here.
 */
private fun cachedName(device: BluetoothDevice): String? = try {
    device.name
} catch (e: SecurityException) {
    null
}
