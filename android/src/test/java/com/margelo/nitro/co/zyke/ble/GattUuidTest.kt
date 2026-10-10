package com.margelo.nitro.co.zyke.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

/** Unit tests for [GattUuid]: the UUID forms the native API accepts (the JS wrapper's set). */
class GattUuidTest {
    private val heartRate = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")

    @Test
    fun shortFormsAreValuesOnTheBluetoothBaseUuid() {
        assertEquals(heartRate, GattUuid.parse("180D"))
        assertEquals(heartRate, GattUuid.parse("180d"))
        assertEquals(heartRate, GattUuid.parse("0000180D"))
        assertEquals(UUID.fromString("1234abcd-0000-1000-8000-00805f9b34fb"), GattUuid.parse("1234ABCD"))
    }

    @Test
    fun longFormsWithAndWithoutDashesInAnyCase() {
        val uuid = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")

        assertEquals(uuid, GattUuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E"))
        assertEquals(uuid, GattUuid.parse("6e400001b5a3f393e0a9e50e24dcca9e"))
    }

    @Test
    fun everythingElseIsRejected() {
        for (text in listOf(
            "",
            "18D",
            "180D1",
            "0x180D",
            "180G",
            " 180D",
            "6e400001-b5a3-f393-e0a9-e50e24dcca9",
            "6e400001-b5a3-f393-e0a9e50e24dcca9e0",
            "6e400001b5a3-f393-e0a9-e50e24dcca9e-",
            "1-2-3-4-5",
            "{6e400001-b5a3-f393-e0a9-e50e24dcca9e}",
            "6e400001-b5a3-f393-e0a9-e50e24dcca9g",
        )) {
            assertNull("\"$text\" should be rejected", GattUuid.parse(text))
        }
    }
}
