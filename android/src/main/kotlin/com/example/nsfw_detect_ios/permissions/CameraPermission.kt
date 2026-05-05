package com.example.nsfw_detect_ios.permissions

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Camera-only permission helper. Mirrors [MediaPermission] but for
 * `Manifest.permission.CAMERA`. The plugin requests at `startCameraScan`
 * time so the host app does not need to pre-request — Phase-01 contract
 * (CAM-06 / CameraScanSession.start) says permission denials flow up the
 * stream as `cameraPermissionDenied` events.
 *
 * Distinct request code (9824) so [MediaPermission]'s own request flow
 * is not confused.
 */
object CameraPermission {

    const val REQUEST_CODE = 9824

    fun isGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Trigger the system permission UI. The result is delivered via
     * [handleResult] (called by [com.example.nsfw_detect_ios.ScanMethodHandler]
     * which forwards from `NsfwDetectPlugin.onRequestPermissionsResult`).
     */
    fun request(activity: Activity, onResult: (Boolean) -> Unit) {
        pending = onResult
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CODE,
        )
    }

    /**
     * Returns `true` if [requestCode] was ours (so the caller knows we
     * consumed it), `false` otherwise. The pending callback is fired with
     * the granted boolean. Safe to call when no callback is pending.
     */
    fun handleResult(
        requestCode: Int,
        @Suppress("UNUSED_PARAMETER") permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val cb = pending
        pending = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        cb?.invoke(granted)
        return true
    }

    @Volatile
    private var pending: ((Boolean) -> Unit)? = null
}
