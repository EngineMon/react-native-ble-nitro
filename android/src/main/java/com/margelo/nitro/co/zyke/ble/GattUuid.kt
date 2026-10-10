package com.margelo.nitro.co.zyke.ble

import java.util.UUID

/**
 * The service and characteristic UUID strings the native API accepts
 * (NativeBleNitro.nitro.ts, section "UUIDs"), the same set on both platforms
 * and in the JS wrapper's parser, so an id is valid or invalid everywhere:
 * - 4 hex digits: a 16-bit UUID ("180D"),
 * - 8 hex digits: a 32-bit UUID ("0000180D"),
 * - 32 hex digits: a 128-bit UUID without dashes,
 * - 36 characters: the canonical 128-bit form, dashes after the 8th, 12th,
 *   16th and 20th hex digit.
 * Letter case doesn't matter. The 16- and 32-bit forms stand for the
 * Bluetooth Base UUID with those bits set (Bluetooth Core Specification
 * Vol 3 Part B §2.5.1): 0000XXXX-0000-1000-8000-00805F9B34FB and
 * XXXXXXXX-0000-1000-8000-00805F9B34FB.
 *
 * java.util.UUID.fromString alone doesn't do: it rejects the short forms and
 * accepts malformed ones ("1-2-3-4-5" parses), which iOS would reject.
 */
internal object GattUuid {
    /** The Bluetooth Base UUID's lower 96 bits, after the 32-bit field. */
    private const val BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"

    /** The UUID [text] names, or null when it isn't one of the accepted forms. */
    fun parse(text: String): UUID? {
        val canonical = when (text.length) {
            4 -> if (isHex(text, 0, 4)) "0000$text$BASE_SUFFIX" else null
            8 -> if (isHex(text, 0, 8)) "$text$BASE_SUFFIX" else null
            32 -> if (isHex(text, 0, 32)) {
                "${text.substring(0, 8)}-${text.substring(8, 12)}-${text.substring(12, 16)}-${text.substring(16, 20)}-${text.substring(20)}"
            } else {
                null
            }
            36 -> if (isCanonical(text)) text else null
            else -> null
        } ?: return null
        return UUID.fromString(canonical)
    }

    private fun isCanonical(text: String): Boolean {
        for (i in text.indices) {
            val dash = i == 8 || i == 13 || i == 18 || i == 23
            if (dash != (text[i] == '-')) return false
            if (!dash && !isHexDigit(text[i])) return false
        }
        return true
    }

    private fun isHex(text: String, from: Int, to: Int): Boolean {
        for (i in from until to) if (!isHexDigit(text[i])) return false
        return true
    }

    private fun isHexDigit(c: Char): Boolean = c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'
}
