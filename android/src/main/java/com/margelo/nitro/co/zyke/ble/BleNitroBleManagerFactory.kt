package com.margelo.nitro.co.zyke.ble

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip

/**
 * Creates the Android managers. The restore identifier and callback are iOS
 * state restoration; Android has none and ignores them.
 *
 * Kept from R8: Nitro creates it by class name from C++ (BleNitroOnLoad.cpp),
 * which R8 can't see.
 */
@DoNotStrip
@Keep
class BleNitroBleManagerFactory : HybridNativeBleNitroFactorySpec() {

    override fun create(
        nativeRestoreStateIdentifier: String?,
        restoreStateCallback: ((peripherals: Array<BLEDevice>) -> Unit)?
    ): HybridNativeBleNitroSpec = BleNitroBleManager()
}
