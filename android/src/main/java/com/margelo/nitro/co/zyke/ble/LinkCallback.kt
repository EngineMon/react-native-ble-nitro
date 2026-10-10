package com.margelo.nitro.co.zyke.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.os.Build
import android.os.Handler

/**
 * What a [LinkCallback] reports to: its link. Implemented privately by
 * [GattConnection], so these entry points aren't part of the link's API.
 */
internal interface LinkEvents {
    /** False once the link is closed; [LinkCallback] then drops every callback. */
    val isOpen: Boolean

    /** The link's session once the link is up; null before. */
    val session: GattSession?

    fun connectionStateChanged(status: Int, newState: Int)

    /** Service Changed (API 31+). */
    fun servicesChanged()
}

/**
 * The BluetoothGattCallback of one link: brings every OS callback onto the
 * manager's executor and hands it to the link, or to its session.
 *
 * One gate for the whole link: once the link is closed ([LinkEvents.isOpen]
 * false) every callback is dropped here, so a late callback from a closed
 * BluetoothGatt never touches the link or session, or the link that replaced
 * it (every link has its own callback object).
 *
 * Threading:
 * - API 27+: connectGatt(..., TRANSPORT_LE, PHY_LE_1M_MASK, handler) makes
 *   the OS run every callback on the handler thread, so they are handled
 *   inline. There, before API 33, the framework sets characteristic.value
 *   right before it calls the callback, so the value is read inside the
 *   callback without a race; API 33+ passes it as a parameter.
 * - API 23-26: connectGatt(..., TRANSPORT_LE) without a handler: callbacks
 *   run on a binder thread, which only takes the value and posts the event
 *   to the handler thread. API 26 has the handler overload, but its
 *   BluetoothGatt sets characteristic.value on the binder thread before
 *   posting to the handler (moved into the posted runnable in 8.1), so a
 *   following notification could replace the value a queued callback is
 *   about to read.
 * - Values: the framework stores each value's own array in the
 *   characteristic (BluetoothGattCharacteristic.setValue keeps the
 *   reference; the framework never writes into an earlier array), so taking
 *   the array before hopping keeps it, and the session copies it per
 *   receiver.
 *
 * On API 33+ BluetoothGatt calls only the overloads that take the value; the
 * deprecated ones are called only below API 33.
 */
internal class LinkCallback(
    private val handler: Handler,
    private val link: LinkEvents,
) : BluetoothGattCallback() {
    /** Runs [event] on the handler thread while the link is open: inline where the OS already calls there (API 27+), posted from the binder thread otherwise. */
    private inline fun onHandler(crossinline event: () -> Unit) {
        if (CALLED_ON_HANDLER) {
            if (link.isOpen) event()
        } else {
            handler.post { if (link.isOpen) event() }
        }
    }

    /** [onHandler] for the session of the link that is up. */
    private inline fun onSession(crossinline event: (session: GattSession) -> Unit) = onHandler {
        link.session?.let { event(it) }
    }

    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = onHandler {
        link.connectionStateChanged(status, newState)
    }

    /** API 31+, on the handler thread. */
    override fun onServiceChanged(gatt: BluetoothGatt) = onHandler {
        link.servicesChanged()
    }

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = onSession {
        it.onServicesDiscovered(status)
    }

    override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = onSession {
        it.onMtuChanged(mtu, status)
    }

    override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) = onSession {
        it.onRssiRead(rssi, status)
    }

    /** API 33+, on the handler thread: [value] is this answer's own array. */
    override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
        onSession { it.onCharacteristicRead(characteristic, value, status) }

    /** Before API 33: the value is taken from the characteristic here, before it can change. */
    @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
    override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
        val value = characteristic.value ?: EMPTY_VALUE
        onSession { it.onCharacteristicRead(characteristic, value, status) }
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = onSession {
        it.onCharacteristicWrite(characteristic, status)
    }

    override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = onSession {
        it.onDescriptorWrite(descriptor, status)
    }

    /** API 33+, on the handler thread: [value] is this notification's own array. */
    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) =
        onSession { it.onCharacteristicChanged(characteristic, value) }

    /** Before API 33: the value is taken from the characteristic here, before a later notification can replace it. */
    @Suppress("OVERRIDE_DEPRECATION", "DEPRECATION")
    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        val value = characteristic.value ?: EMPTY_VALUE
        onSession { it.onCharacteristicChanged(characteristic, value) }
    }

    companion object {
        /**
         * API 27+: [GattConnection] opens the link with connectGatt's handler
         * overload, and the OS runs every callback on that handler (see the
         * class comment). One flag for both, so the overload and the
         * callback's threading can't disagree.
         */
        val CALLED_ON_HANDLER = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1

        /** A value the framework left null: no bytes. */
        private val EMPTY_VALUE = ByteArray(0)
    }
}
