package com.example.nsfw_detect_ios.camera

import com.example.nsfw_detect_ios.ml.ModelIds

/**
 * Kotlin mirror of Phase-01 `CameraConfiguration.toChannelMap()`. Decoded
 * from the method-channel argument map in [com.example.nsfw_detect_ios.ScanMethodHandler]
 * before being passed to [CameraSessionTask].
 *
 * Fields match the wire keys produced by `lib/src/api/camera_configuration.dart`
 * (`toChannelMap`). `iosComputeUnits` is intentionally ignored on Android.
 */
internal data class CameraSessionConfig(
    val modelId: String,
    val confidenceThreshold: Double,
    /** "classification" | "detection" — see [com.example.nsfw_detect_ios.scanner.ScanConfiguration]. */
    val mode: String,
    /** 1..30 — frame-throttle target. Default 2 (matches CAM-01 default). */
    val fps: Int,
    /** "low" | "medium" | "high" — informational, native picks resolution from model inputSize. */
    val resolution: String,
    val detectionConfidenceThreshold: Double,
    val iouThreshold: Double,
    /** Optional TFLite delegate hint ("gpu" | "nnapi" | null). */
    val androidDelegate: String?,
    /** "back" | "front" — default "back". Phase-01 contract does not require this yet,
     *  read defensively. */
    val lensDirection: String,
) {
    companion object {
        fun from(args: Map<*, *>): CameraSessionConfig = CameraSessionConfig(
            modelId = args["modelId"] as? String ?: ModelIds.OPEN_NSFW_2,
            confidenceThreshold = (args["confidenceThreshold"] as? Number)?.toDouble() ?: 0.7,
            mode = args["mode"] as? String ?: "classification",
            fps = (args["fps"] as? Number)?.toInt()?.coerceIn(1, 30) ?: 2,
            resolution = args["resolution"] as? String ?: "medium",
            detectionConfidenceThreshold =
                (args["detectionConfidenceThreshold"] as? Number)?.toDouble() ?: 0.25,
            iouThreshold = (args["iouThreshold"] as? Number)?.toDouble() ?: 0.45,
            androidDelegate = args["androidDelegate"] as? String,
            lensDirection = args["lensDirection"] as? String ?: "back",
        )
    }
}
