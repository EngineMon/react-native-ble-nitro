package com.margelo.nitro.co.zyke.ble

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.ActivityNotFoundException
import android.content.Intent
import com.facebook.react.bridge.BaseActivityEventListener
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.common.LifecycleState
import java.util.concurrent.Executor

/**
 * requestBluetoothEnable: asks the user to turn Bluetooth on
 * (BluetoothAdapter.ACTION_REQUEST_ENABLE) and completes with the answer.
 * - Bluetooth is on already: completes at once without error.
 * - The dialog's activity result: RESULT_OK, without error (the dialog
 *   returns it once the adapter is on); anything else, OperationCancelled.
 *   Bluetooth reaching STATE_ON meanwhile ([adapterOn]) also succeeds.
 * - No activity to ask from: BluetoothStateChangeFailed. Only an activity can
 *   start the dialog and learn the answer, and it must be resumed: Android
 *   10+ silently drops activity starts from the background ("Restrictions on
 *   starting activities from the background"), so the call would never end.
 * - Calls made while the dialog is up wait for the same answer.
 * - The manager's teardown fails the waiting calls ([finish]).
 *
 * Confined to the manager's executor. [osEvents] brings the activity result
 * (main thread) and a failed start onto it, and drops them once the manager
 * is destroyed (its teardown completes the waiting calls).
 */
internal class BluetoothEnableRequest(private val osEvents: Executor) {
    private val waiting = ArrayList<Reply<Unit, BleError>>()

    /** The React context [resultListener] is registered with while calls wait. */
    private var context: ReactApplicationContext? = null

    /**
     * Runs on the main thread for every activity result of the app; the
     * dialog's has [REQUEST_CODE]. Every manager uses that code, so with two
     * managers asking at once each takes the first answer: both asked about
     * the one adapter.
     */
    private val resultListener = object : BaseActivityEventListener() {
        override fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
            if (requestCode != REQUEST_CODE) return
            osEvents.execute {
                finish(if (resultCode == Activity.RESULT_OK) null else enableDeclinedError(resultCode))
            }
        }
    }

    fun request(adapter: BluetoothAdapter, reply: Reply<Unit, BleError>) {
        if (adapter.isEnabled) return reply.succeed()
        if (waiting.isNotEmpty()) {
            waiting.add(reply)
            return
        }
        val context = BleNitroLifecycle.reactContext()
        val activity = context?.currentActivity
        if (context == null || activity == null || context.lifecycleState != LifecycleState.RESUMED) {
            return reply.fail(noForegroundActivityError())
        }
        waiting.add(reply)
        this.context = context
        context.addActivityEventListener(resultListener)
        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
        // Activities are started from the main thread.
        activity.runOnUiThread {
            val failure = try {
                activity.startActivityForResult(intent, REQUEST_CODE)
                null
            } catch (e: SecurityException) {
                // API 33+: ACTION_REQUEST_ENABLE needs BLUETOOTH_CONNECT.
                unauthorizedError("Requesting Bluetooth enable", e)
            } catch (e: ActivityNotFoundException) {
                noEnableActivityError()
            }
            if (failure != null) osEvents.execute { finish(failure) }
        }
    }

    /** The adapter reached STATE_ON: the waiting calls succeed. */
    fun adapterOn() = finish(null)

    /** Ends the wait for the dialog's answer and completes every waiting call: without error when [error] is null. */
    fun finish(error: BleError?) {
        if (waiting.isEmpty()) return
        val replies = waiting.toList()
        waiting.clear()
        context?.removeActivityEventListener(resultListener)
        context = null
        for (reply in replies) if (error == null) reply.succeed() else reply.fail(error)
    }

    private companion object {
        /** The dialog's activity request code; within the lower 16 bits, which androidx activities require. */
        const val REQUEST_CODE = 0xB1E
    }
}
