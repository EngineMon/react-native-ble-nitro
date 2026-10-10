package com.margelo.nitro.co.zyke.ble

import kotlin.math.ceil

/**
 * Limits and checks the Bluetooth Core Specification puts on GATT clients,
 * checked before a request reaches the OS so that a request the OS would
 * refuse, truncate or misreport fails with a clear error instead.
 *
 * Property bits are the characteristic properties of the Bluetooth Core
 * Specification (Vol 3 Part G §3.3.1.1); Android's
 * BluetoothGattCharacteristic.PROPERTY_* and iOS's CBCharacteristicProperties
 * use the same bits, so the platform code passes its properties value
 * unchanged.
 */
internal object GattRules {
    /** The LE ATT_MTU before any MTU exchange (Bluetooth Core Specification Vol 3 Part G §5.2.1). */
    const val DEFAULT_ATT_MTU = 23

    /** Bytes of an ATT write PDU that aren't value: opcode + attribute handle (Bluetooth Core Specification Vol 3 Part F §3.4.5). */
    const val ATT_WRITE_HEADER = 3

    /** The longest attribute value (Bluetooth Core Specification Vol 3 Part F §3.2.9). */
    const val MAX_ATTRIBUTE_LENGTH = 512

    /** The largest ATT_MTU an MTU request may ask for: what Android negotiates at most, a 512-byte value plus the 5-byte header of the longest ATT PDU. */
    const val MAX_ATT_MTU = 517

    /** An ATT transaction that isn't answered within 30 s has timed out (Bluetooth Core Specification Vol 3 Part F §3.3.3). */
    const val ATT_TRANSACTION_TIMEOUT_MS = 30_000L

    const val PROPERTY_READ = 0x02
    const val PROPERTY_WRITE_WITHOUT_RESPONSE = 0x04
    const val PROPERTY_WRITE = 0x08
    const val PROPERTY_NOTIFY = 0x10
    const val PROPERTY_INDICATE = 0x20

    /**
     * What an operation does with a characteristic. A write carries its length
     * and type, so a write can't be checked without its length rule.
     */
    sealed interface Access {
        data object Read : Access

        /** Subscribing: notifications or indications. */
        data object Notify : Access

        data class Write(val length: Int, val withResponse: Boolean) : Access
    }

    /** Why a request can't go to the OS. The platform code maps it to a BleError naming the characteristic. */
    sealed interface Violation {
        /** The characteristic's properties don't allow [access]. */
        data class NotPermitted(val access: Access) : Violation

        /** A write of [length] bytes is over the [limit] for its write type. */
        data class TooLong(val length: Int, val limit: Int) : Violation
    }

    /**
     * Whether a characteristic with [properties] allows [access], on a link
     * whose Write Command holds at most [maxWithoutResponse] bytes. The
     * permission is checked first, then a write's length.
     *
     * Permission. Strict: each access requires its own property bit. The OS
     * checks are partial (Android refuses a read without the read bit as a
     * bare start failure and accepts either write bit for both write types),
     * so without this check a mismatch surfaces as an unexplained start
     * failure, an ATT error from the peripheral, or a write command the
     * peripheral drops. [Access.Notify] accepts notify or indicate:
     * subscribing writes whichever the characteristic supports (see
     * [cccdSubscriptionMode]).
     *
     * Length of a write:
     * - Both types: no attribute value is longer than [MAX_ATTRIBUTE_LENGTH]
     *   (Bluetooth Core Specification Vol 3 Part F §3.2.9). Android 15 rejects
     *   a longer write, Android 6 to 14 silently truncate it to 512 bytes.
     * - Without response (an ATT Write Command): the value must fit one PDU,
     *   ATT_MTU − 3 bytes (Vol 3 Part G §4.9.1), passed in as
     *   [maxWithoutResponse] by the platform code (Android: the link's MTU − 3;
     *   iOS: maximumWriteValueLength(for: .withoutResponse)). Android
     *   truncates a longer value silently. The limit is the smaller of the
     *   two, as a 517 MTU would otherwise allow 514 bytes.
     * - With response, a value longer than one PDU goes out as a long write
     *   (Prepare/Execute Write), so only the 512-byte limit applies.
     */
    fun violation(access: Access, properties: Int, maxWithoutResponse: Int): Violation? {
        val required = when (access) {
            Access.Read -> PROPERTY_READ
            Access.Notify -> PROPERTY_NOTIFY or PROPERTY_INDICATE
            is Access.Write -> if (access.withResponse) PROPERTY_WRITE else PROPERTY_WRITE_WITHOUT_RESPONSE
        }
        if ((properties and required) == 0) return Violation.NotPermitted(access)
        if (access !is Access.Write) return null
        val limit = if (access.withResponse) MAX_ATTRIBUTE_LENGTH else minOf(maxWithoutResponse, MAX_ATTRIBUTE_LENGTH)
        return if (access.length > limit) Violation.TooLong(access.length, limit) else null
    }

    /** When a connect attempt gives up. No invalid case: the facade rejects an invalid `timeoutMs` ([connectDeadline]). */
    sealed interface ConnectDeadline {
        /** The attempt runs until it connects, fails or is cancelled. */
        data object Never : ConnectDeadline

        /** Give up after [ms] milliseconds. */
        data class After(val ms: Long) : ConnectDeadline
    }

    /**
     * The longest connect timeout honored, 2^31 − 1 ms (24.8 days): longer ones
     * saturate to it. A cap is needed because Android's Handler adds the delay
     * to the current uptime, and a delay near Long.MAX_VALUE overflows into a
     * time in the past, which runs the timeout at once. The same cap on iOS
     * keeps both platforms' answers identical.
     */
    private const val MAX_CONNECT_TIMEOUT_MS = Int.MAX_VALUE.toLong()

    /**
     * Interprets a connect call's `timeoutMs` (a JS number). Absent or +∞:
     * [ConnectDeadline.Never]. A finite value > 0: [ConnectDeadline.After]
     * that many ms, rounded up (so a fraction of a millisecond never becomes
     * 0, an immediate timeout) and saturated to [MAX_CONNECT_TIMEOUT_MS].
     * NaN, ≤ 0 or −∞: null, invalid (the connect fails with
     * OperationStartFailed "invalid timeoutMs"), instead of a conversion that
     * would trap (iOS) or silently become 0 (Kotlin's NaN.toLong()).
     */
    fun connectDeadline(timeoutMs: Double?): ConnectDeadline? = when {
        timeoutMs == null || timeoutMs == Double.POSITIVE_INFINITY -> ConnectDeadline.Never
        timeoutMs.isNaN() || timeoutMs <= 0.0 -> null
        timeoutMs >= MAX_CONNECT_TIMEOUT_MS -> ConnectDeadline.After(MAX_CONNECT_TIMEOUT_MS)
        else -> ConnectDeadline.After(ceil(timeoutMs).toLong())
    }

    /**
     * The MTU an MTU request asks for, when it is an integer in
     * [DEFAULT_ATT_MTU]..[MAX_ATT_MTU]; null otherwise (the request fails with
     * DeviceMTUChangeFailed). No LE ATT_MTU is below 23 (Bluetooth Core
     * Specification Vol 3 Part G §5.2.1), 517 is the most Android negotiates,
     * and a fractional value would be truncated without notice.
     */
    fun validMtuRequest(mtu: Double): Int? =
        if (mtu >= DEFAULT_ATT_MTU && mtu <= MAX_ATT_MTU && mtu == ceil(mtu)) mtu.toInt() else null

    /**
     * The delivery mode to request via the CCCD descriptor when subscribing to a
     * characteristic, derived from the characteristic's declared properties.
     */
    enum class CccdSubscriptionMode {
        /** Use ENABLE_NOTIFICATION_VALUE (unacknowledged delivery). */
        NOTIFY,

        /** Use ENABLE_INDICATION_VALUE (acknowledged delivery). */
        INDICATE,

        /** The characteristic supports neither notify nor indicate. */
        UNSUPPORTED,
    }

    /**
     * Selects the CCCD subscription mode for a characteristic's [properties] bitmask.
     *
     * Notification is preferred when the characteristic supports both notify and
     * indicate because it is unacknowledged and lower-overhead. Indication is used
     * only for indicate-only characteristics. This mirrors iOS CoreBluetooth, where
     * `setNotifyValue(true)` automatically selects the appropriate delivery mode.
     */
    fun cccdSubscriptionMode(properties: Int): CccdSubscriptionMode = when {
        (properties and PROPERTY_NOTIFY) != 0 -> CccdSubscriptionMode.NOTIFY
        (properties and PROPERTY_INDICATE) != 0 -> CccdSubscriptionMode.INDICATE
        else -> CccdSubscriptionMode.UNSUPPORTED
    }
}
