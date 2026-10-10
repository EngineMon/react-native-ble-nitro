package com.margelo.nitro.co.zyke.ble

import android.Manifest
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import kotlin.math.min

/**
 * What the app needs for Android to deliver scan results, checked before a
 * scan starts. Without it Android either refuses the scan or, worse, runs it
 * without ever delivering a result, so the caller would wait for nothing.
 * The rules are Android's (Bluetooth permissions guide, "Declare Bluetooth
 * permissions" and "Strongly assert that your app doesn't derive physical
 * location").
 */
internal object ScanPreconditions {
    /**
     * Whether the app declares BLUETOOTH_SCAN with
     * usesPermissionFlags="neverForLocation"; read once from the manifest,
     * which doesn't change while the process runs. Racing first reads compute
     * the same value.
     */
    @Volatile
    private var neverForLocation: Boolean? = null

    /** Why a scan can't deliver results now (missing permission, location services off), or null. */
    fun check(context: Context): BleError? {
        missingPermission(context)?.let { return scanPermissionMissingError(it) }
        if (locationServicesRequired(context) && !locationServicesEnabled(context)) return locationServicesDisabledError()
        return null
    }

    /**
     * The runtime permission scanning needs that isn't granted, if any, by
     * [effectiveSdk]: BLUETOOTH_SCAN from API 31, plus fine location unless
     * BLUETOOTH_SCAN is declared neverForLocation; fine location on API 29-30;
     * fine or coarse location before.
     */
    private fun missingPermission(context: Context): String? {
        // Every inner list must have one granted permission.
        val required = when {
            effectiveSdk(context) >= Build.VERSION_CODES.S -> if (scanNeverForLocation(context)) {
                listOf(listOf(Manifest.permission.BLUETOOTH_SCAN))
            } else {
                listOf(listOf(Manifest.permission.BLUETOOTH_SCAN), listOf(Manifest.permission.ACCESS_FINE_LOCATION))
            }
            effectiveSdk(context) >= Build.VERSION_CODES.Q -> listOf(listOf(Manifest.permission.ACCESS_FINE_LOCATION))
            else -> listOf(listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }
        val missing = required.firstOrNull { anyOf ->
            anyOf.none { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
        }
        return missing?.joinToString(" or ")
    }

    /**
     * Whether Android delivers scan results only while location services are
     * on: always before API 31 (except on Wear OS), from API 31 unless
     * BLUETOOTH_SCAN is declared neverForLocation.
     */
    private fun locationServicesRequired(context: Context): Boolean {
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH)) return false
        return !scanNeverForLocation(context)
    }

    /** Whether the app (API 31+, targeting 31+) declares BLUETOOTH_SCAN with usesPermissionFlags="neverForLocation". */
    @Suppress("DEPRECATION")
    private fun scanNeverForLocation(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || context.applicationInfo.targetSdkVersion < Build.VERSION_CODES.S) return false
        neverForLocation?.let { return it }
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        val index = info.requestedPermissions?.indexOf(Manifest.permission.BLUETOOTH_SCAN) ?: -1
        val flags = info.requestedPermissionsFlags
        val declared = index >= 0 && flags != null &&
            (flags[index] and PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0
        neverForLocation = declared
        return declared
    }

    private fun locationServicesEnabled(context: Context): Boolean =
        LocationManagerCompat.isLocationEnabled(context.getSystemService(Context.LOCATION_SERVICE) as LocationManager)

    /** The API level whose permission model applies: the device's, capped by the app's target. */
    private fun effectiveSdk(context: Context): Int = min(Build.VERSION.SDK_INT, context.applicationInfo.targetSdkVersion)
}
