package com.margelo.nitro.co.zyke.ble

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.turbomodule.core.interfaces.TurboModule
import com.margelo.nitro.NitroModules
import java.util.concurrent.atomic.AtomicReference

/**
 * Ties the BLE managers to the lifecycle of the React Native instance (the JS
 * runtime). It has no JS API: JS never calls it, React Native creates it with
 * every instance because [BleNitroPackage] declares it eager-init.
 *
 * Why it exists:
 * - A JS reload must tear down every manager the old runtime created: close
 *   its GATT clients (the OS otherwise keeps the links, their CCCDs and their
 *   notifications going), stop its scan (it counts against the app's scan
 *   start budget and drains the battery), unregister its adapter receiver and
 *   end its thread. Nitro calls a HybridObject's `dispose()` only when JS
 *   calls it by hand, and has no finalizer, so a manager of the old runtime
 *   (a pinned singleton, or one held by C++) would live on, still connected,
 *   next to the new runtime's managers. [invalidate] is the signal.
 * - `requestBluetoothEnable` asks the user through the current activity and
 *   learns the answer from its activity result. Both come from the instance's
 *   [ReactApplicationContext], which only a module receives.
 *
 * Why this hook is reliable (React Native 0.84 sources):
 * - Bridgeless creates a TurboModule only when JS requests it, or eagerly
 *   when its ReactModuleInfo has `needsEagerInit` and `isTurboModule`
 *   (ReactPackageTurboModuleManagerDelegate.getEagerInitModuleNames;
 *   ReactInstance.initializeEagerTurboModules runs while the instance starts).
 *   The delegate hands out only modules that implement [TurboModule]; a plain
 *   Kotlin module is fine, the Java object never needs a codegen'd JSI binding
 *   because JS never calls it.
 * - ReactInstance.destroy() (reload and ReactHost teardown alike) calls
 *   TurboModuleManager.invalidate(), which calls [invalidate] on every module
 *   it created. The reload task destroys the old instance before it creates
 *   the next one, so the next runtime's managers don't exist yet: one JS
 *   runtime per process, and every live manager at that moment belongs to the
 *   runtime going away.
 * - The JS thread is already gone when [invalidate] runs (ReactInstance
 *   destroys its queues first). The teardown fires no listener (destroy()
 *   silences them); the JS completions it fails with BluetoothManagerDestroyed
 *   are dropped by Nitro; C++ completions still run, on the manager's thread.
 */
internal class BleNitroLifecycle(
    private val context: ReactApplicationContext,
) : ReactContextBaseJavaModule(context), TurboModule {

    init {
        current.set(this)
    }

    override fun getName(): String = NAME

    /**
     * The instance is going away: forget its context (requestBluetoothEnable
     * then has no activity to ask from until the next instance's module
     * exists), then destroy every live manager. Each destroy waits only until
     * no listener of its manager runs (its barrier), not for the teardown,
     * which runs on the manager's own thread afterwards.
     */
    override fun invalidate() {
        // Only its own: a later instance's module may have replaced it already.
        current.compareAndSet(this, null)
        BleCore.destroyAll()
    }

    companion object {
        const val NAME = "BleNitroLifecycle"

        private const val TAG = "BleNitro"

        private val current = AtomicReference<BleNitroLifecycle?>(null)

        /** The live instance's React context; null before its module exists and after it was invalidated. */
        fun reactContext(): ReactApplicationContext? = current.get()?.context

        /**
         * The app context. NitroModules sets its React context when JS
         * installs Nitro, before any HybridObject exists; the Application via
         * ActivityThread covers a manager created where that never ran.
         */
        fun appContext(): Context? = NitroModules.applicationContext?.applicationContext ?: currentApplication()

        @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
        private fun currentApplication(): Context? = try {
            Class.forName("android.app.ActivityThread").getMethod("currentApplication").invoke(null) as? Context
        } catch (e: ReflectiveOperationException) {
            Log.e(TAG, "No app context: NitroModules has none and ActivityThread.currentApplication() is unavailable", e)
            null
        }
    }
}
