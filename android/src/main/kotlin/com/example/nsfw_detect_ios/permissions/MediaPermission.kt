package com.example.nsfw_detect_ios.permissions

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * 3-tier permission helper for media access.
 * Selects the correct permission string based on Android API level:
 * - API >= 34: READ_MEDIA_VISUAL_USER_SELECTED (partial) / READ_MEDIA_IMAGES (full)
 * - API 33: READ_MEDIA_IMAGES
 * - API <= 32: READ_EXTERNAL_STORAGE
 */
object MediaPermission {

    const val REQUEST_CODE = 9823

    /**
     * Returns the current permission status as a string:
     * "authorized", "limited", "denied", "notDetermined"
     */
    fun checkPermission(context: Context): String {
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                // API >= 34: check full vs partial vs none
                val fullGranted = ContextCompat.checkSelfPermission(
                    context, Manifest.permission.READ_MEDIA_IMAGES
                ) == PackageManager.PERMISSION_GRANTED
                if (fullGranted) return "authorized"

                val partialGranted = ContextCompat.checkSelfPermission(
                    context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
                ) == PackageManager.PERMISSION_GRANTED
                if (partialGranted) return "limited"

                "notDetermined"
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                // API 33
                val granted = ContextCompat.checkSelfPermission(
                    context, Manifest.permission.READ_MEDIA_IMAGES
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) "authorized" else "notDetermined"
            }
            else -> {
                // API <= 32
                val granted = ContextCompat.checkSelfPermission(
                    context, Manifest.permission.READ_EXTERNAL_STORAGE
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) "authorized" else "notDetermined"
            }
        }
    }

    /**
     * Request media permissions from an Activity.
     * The result is delivered via onRequestPermissionsResult.
     * Stores the pending result callback for resolution in handlePermissionResult.
     */
    fun requestPermission(activity: Activity, result: MethodChannel.Result) {
        pendingResult = result
        val permissions = requiredPermissions()
        ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE)
    }

    /**
     * Fallback when no Activity is available — returns "notDetermined".
     */
    fun requestPermissionWithoutActivity(result: MethodChannel.Result) {
        android.util.Log.w("MediaPermission", "requestPermission called without an Activity — returning notDetermined")
        result.success("notDetermined")
    }

    /**
     * Handle the result of a permission request.
     * Returns true if this was our request code (consumed), false otherwise.
     */
    fun handlePermissionResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val pending = pendingResult ?: return true
        pendingResult = null

        val status = resolvePermissionResult(permissions, grantResults)
        pending.success(status)
        return true
    }

    /**
     * Resolve the granted permissions array to a status string.
     */
    private fun resolvePermissionResult(
        permissions: Array<out String>,
        grantResults: IntArray
    ): String {
        if (grantResults.isEmpty()) return "denied"

        val grantMap = permissions.zip(grantResults.toTypedArray()).toMap()

        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                val fullGranted = grantMap[Manifest.permission.READ_MEDIA_IMAGES] == PackageManager.PERMISSION_GRANTED
                if (fullGranted) return "authorized"

                val partialGranted = grantMap[Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED] == PackageManager.PERMISSION_GRANTED
                if (partialGranted) return "limited"

                "denied"
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                val granted = grantMap[Manifest.permission.READ_MEDIA_IMAGES] == PackageManager.PERMISSION_GRANTED
                if (granted) "authorized" else "denied"
            }
            else -> {
                val granted = grantMap[Manifest.permission.READ_EXTERNAL_STORAGE] == PackageManager.PERMISSION_GRANTED
                if (granted) "authorized" else "denied"
            }
        }
    }

    /**
     * Returns the required permissions array for the current API level.
     */
    fun requiredPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
        )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES
        )
        else -> arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE
        )
    }

    // Pending result callback for async permission request
    @Volatile
    private var pendingResult: MethodChannel.Result? = null
}
