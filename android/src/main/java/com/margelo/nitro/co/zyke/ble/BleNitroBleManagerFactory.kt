package com.margelo.nitro.co.zyke.ble

/**
 * Creates the Android managers. The restore identifier and callback are iOS
 * state restoration; Android has none and ignores them.
 */
class BleNitroBleManagerFactory : HybridNativeBleNitroFactorySpec() {

    override fun create(
        nativeRestoreStateIdentifier: String?,
        restoreStateCallback: ((peripherals: Array<BLEDevice>) -> Unit)?
    ): HybridNativeBleNitroSpec = BleNitroBleManager()
}
