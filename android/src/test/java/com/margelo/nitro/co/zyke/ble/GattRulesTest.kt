package com.margelo.nitro.co.zyke.ble

import com.margelo.nitro.co.zyke.ble.GattRules.Access
import com.margelo.nitro.co.zyke.ble.GattRules.CccdSubscriptionMode
import com.margelo.nitro.co.zyke.ble.GattRules.ConnectDeadline
import com.margelo.nitro.co.zyke.ble.GattRules.Violation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for [GattRules]. Property bits are written out as the Bluetooth
 * Core Specification's characteristic properties (Vol 3 Part G §3.3.1.1), not
 * taken from [GattRules], so a wrong constant there fails here.
 */
class GattRulesTest {
    private val read = 0x02
    private val writeWithoutResponse = 0x04
    private val write = 0x08
    private val notify = 0x10
    private val indicate = 0x20

    private fun violation(access: Access, properties: Int, maxWithoutResponse: Int = 20) =
        GattRules.violation(access, properties, maxWithoutResponse)

    @Test
    fun eachAccessRequiresItsOwnPropertyBit() {
        val writeRequest = Access.Write(length = 1, withResponse = true)
        val writeCommand = Access.Write(length = 1, withResponse = false)
        assertNull(violation(Access.Read, read))
        assertNull(violation(writeRequest, write))
        assertNull(violation(writeCommand, writeWithoutResponse))

        assertEquals(Violation.NotPermitted(Access.Read), violation(Access.Read, write or notify))
        assertEquals(Violation.NotPermitted(writeRequest), violation(writeRequest, writeWithoutResponse))
        assertEquals(Violation.NotPermitted(writeCommand), violation(writeCommand, write))
    }

    @Test
    fun notifyAcceptsNotifyOrIndicate() {
        assertNull(violation(Access.Notify, notify))
        assertNull(violation(Access.Notify, indicate))
        assertEquals(Violation.NotPermitted(Access.Notify), violation(Access.Notify, read or write))
    }

    @Test
    fun permissionIsCheckedBeforeLength() {
        val tooLong = Access.Write(length = 600, withResponse = true)

        assertEquals(Violation.NotPermitted(tooLong), violation(tooLong, writeWithoutResponse))
    }

    @Test
    fun writeWithResponseIsLimitedTo512Bytes() {
        assertNull(violation(Access.Write(512, withResponse = true), write, maxWithoutResponse = 20))
        assertEquals(
            Violation.TooLong(513, 512),
            violation(Access.Write(513, withResponse = true), write, maxWithoutResponse = 514),
        )
    }

    @Test
    fun writeWithoutResponseIsLimitedToOnePdu() {
        // ATT_MTU 512: 509 bytes of value fit one Write Command.
        assertNull(violation(Access.Write(509, withResponse = false), writeWithoutResponse, maxWithoutResponse = 509))
        assertEquals(
            Violation.TooLong(510, 509),
            violation(Access.Write(510, withResponse = false), writeWithoutResponse, maxWithoutResponse = 509),
        )
    }

    @Test
    fun writeWithoutResponseIsLimitedTo512BytesEvenWhenOnePduHoldsMore() {
        // ATT_MTU 517: one PDU would hold 514 bytes, an attribute value only 512.
        assertNull(violation(Access.Write(512, withResponse = false), writeWithoutResponse, maxWithoutResponse = 514))
        assertEquals(
            Violation.TooLong(513, 512),
            violation(Access.Write(513, withResponse = false), writeWithoutResponse, maxWithoutResponse = 514),
        )
    }

    @Test
    fun absentOrInfiniteTimeoutHasNoDeadline() {
        assertEquals(ConnectDeadline.Never, GattRules.connectDeadline(null))
        assertEquals(ConnectDeadline.Never, GattRules.connectDeadline(Double.POSITIVE_INFINITY))
    }

    @Test
    fun connectDeadlineIsRoundedUpToWholeMillisecondsAndCapped() {
        val max = Int.MAX_VALUE.toLong()
        assertEquals(ConnectDeadline.After(1_000), GattRules.connectDeadline(1_000.0))
        assertEquals(ConnectDeadline.After(1), GattRules.connectDeadline(0.25))
        assertEquals(ConnectDeadline.After(1_001), GattRules.connectDeadline(1_000.5))
        assertEquals(ConnectDeadline.After(max), GattRules.connectDeadline(Int.MAX_VALUE.toDouble()))
        assertEquals(ConnectDeadline.After(max), GattRules.connectDeadline(Int.MAX_VALUE + 0.5))
        assertEquals(ConnectDeadline.After(max), GattRules.connectDeadline(1e300))
    }

    @Test
    fun connectDeadlineRejectsNaNZeroNegativeAndMinusInfinity() {
        for (ms in listOf(Double.NaN, 0.0, -0.0, -1.0, Double.NEGATIVE_INFINITY)) {
            assertNull("timeoutMs $ms", GattRules.connectDeadline(ms))
        }
    }

    @Test
    fun mtuRequestMustBeAnIntegerFrom23To517() {
        assertEquals(23, GattRules.validMtuRequest(23.0))
        assertEquals(517, GattRules.validMtuRequest(517.0))
        for (mtu in listOf(22.0, 518.0, 185.5, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull("mtu $mtu", GattRules.validMtuRequest(mtu))
        }
    }

    // CCCD mode selection (Android only: CoreBluetooth picks notify or indicate itself).

    @Test
    fun notifyOnly_usesNotify() {
        assertEquals(CccdSubscriptionMode.NOTIFY, GattRules.cccdSubscriptionMode(notify))
    }

    @Test
    fun indicateOnly_usesIndicate() {
        assertEquals(CccdSubscriptionMode.INDICATE, GattRules.cccdSubscriptionMode(indicate))
    }

    @Test
    fun supportsBoth_prefersNotify() {
        assertEquals(CccdSubscriptionMode.NOTIFY, GattRules.cccdSubscriptionMode(notify or indicate))
    }

    @Test
    fun indicateWithOtherProperties_usesIndicate() {
        assertEquals(CccdSubscriptionMode.INDICATE, GattRules.cccdSubscriptionMode(indicate or read))
    }

    @Test
    fun neitherNotifyNorIndicate_isUnsupported() {
        assertEquals(CccdSubscriptionMode.UNSUPPORTED, GattRules.cccdSubscriptionMode(read))
    }

    @Test
    fun noProperties_isUnsupported() {
        assertEquals(CccdSubscriptionMode.UNSUPPORTED, GattRules.cccdSubscriptionMode(0))
    }
}
