package com.margelo.nitro.co.zyke.ble

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * The library's React Native package (autolinked). The BLE manager itself is a
 * Nitro HybridObject and needs no React module; the package provides:
 * - the native library: loading this class loads libBleNitro (the Nitro
 *   bindings), as every Nitro module's package does;
 * - [BleNitroLifecycle], an eager-init TurboModule without JS API that tears
 *   the managers of a JS runtime down when React Native invalidates it, and
 *   hands requestBluetoothEnable the instance's activity.
 *
 * Eager init is what makes the lifecycle module exist at all: bridgeless
 * React Native creates a TurboModule only when JS asks for it or when its
 * ReactModuleInfo has `needsEagerInit` (and `isTurboModule`), and JS never
 * asks for this one. Like NitroModulesPackage, `isTurboModule` follows the
 * architecture: on the old architecture the module is a legacy native module,
 * whose eager init and `invalidate()` the bridge provides the same way.
 */
class BleNitroPackage : BaseReactPackage() {

    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == BleNitroLifecycle.NAME) BleNitroLifecycle(reactContext) else null

    override fun getReactModuleInfoProvider(): ReactModuleInfoProvider = ReactModuleInfoProvider {
        mapOf(
            BleNitroLifecycle.NAME to ReactModuleInfo(
                BleNitroLifecycle.NAME,
                BleNitroLifecycle::class.java.name,
                false, // canOverrideExistingModule
                true, // needsEagerInit
                false, // isCxxModule
                BuildConfig.IS_NEW_ARCHITECTURE_ENABLED, // isTurboModule
            ),
        )
    }

    companion object {
        init {
            BleNitroOnLoad.initializeNative()
        }
    }
}
