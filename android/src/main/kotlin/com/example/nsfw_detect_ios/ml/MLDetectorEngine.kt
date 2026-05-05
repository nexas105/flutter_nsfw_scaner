package com.example.nsfw_detect_ios.ml

import android.graphics.Bitmap

/**
 * Sibling interface to [MLEngine] for object-detection (bounding-box) models
 * like NudeNet. Mirrors `ios/Classes/ml/MLDetectorEngine.swift`.
 *
 * Implementations return a list of [BodyPartDetection]s per bitmap, with
 * normalised bounding boxes (origin top-left, all values in `[0, 1]`).
 */
interface MLDetectorEngine {
    val descriptor: ModelDescriptorNative

    /** Load the model into memory. Idempotent. */
    suspend fun load()

    /** Free model resources. Safe to call multiple times. */
    fun unload()

    /** Run object detection on one bitmap. Implementations MUST be safe to call concurrently. */
    suspend fun detect(bitmap: Bitmap): List<BodyPartDetection>

    /**
     * Batched detection. Default implementation runs serially so engines
     * don't have to override.
     */
    suspend fun detectBatch(bitmaps: List<Bitmap>): List<List<BodyPartDetection>> {
        val results = ArrayList<List<BodyPartDetection>>(bitmaps.size)
        for (bmp in bitmaps) results.add(detect(bmp))
        return results
    }

    /**
     * Hint preferred TFLite delegate at [load] time. Pass null for CPU.
     * Engines that don't expose delegate selection treat this as a no-op.
     */
    fun setPreferredAcceleratorDelegate(delegate: String?) { /* no-op */ }

    /** Confidence floor — boxes below this are dropped. No-op default. */
    fun setMinConfidence(minConfidence: Float) { /* no-op */ }

    /** Delegate string the loaded model was built with (null until loaded / on CPU). */
    val loadedDelegate: String?
        get() = null
}

/**
 * Single body-part bounding-box detection. Mirrors Dart `BodyPartDetection`
 * and Swift `BodyPartDetectionNative`.
 *
 * `box` is normalised `[0, 1]` with origin **top-left**; `width`/`height` are
 * extents (NOT corner coordinates).
 */
data class BodyPartDetection(
    /** Raw class label from the detector (e.g. `FEMALE_BREAST_EXPOSED`). */
    val label: String,
    val confidence: Float,
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
    /** Canonical bucket — one of `safe | suggestive | nudity | explicitNudity | unknown`. */
    val aggregatedCategory: String,
) {
    fun toMap(): Map<String, Any> = mapOf(
        "label" to label,
        "confidence" to confidence.toDouble(),
        "aggregatedCategory" to aggregatedCategory,
        "box" to mapOf(
            "x" to x.toDouble(),
            "y" to y.toDouble(),
            "width" to width.toDouble(),
            "height" to height.toDouble(),
        ),
    )

    companion object {
        /**
         * Canonical NudeNet-label → category mapping. Mirrors the Dart
         * `BodyPartDetection.aggregateCategoryFromLabel` and the Swift
         * `BodyPartDetectionNative.aggregateCategory(forLabel:)` helpers.
         */
        fun aggregateCategoryFor(rawLabel: String): String {
            return when (rawLabel.trim().uppercase()) {
                "FEMALE_GENITALIA_EXPOSED",
                "MALE_GENITALIA_EXPOSED",
                "ANUS_EXPOSED" -> "explicitNudity"

                "FEMALE_BREAST_EXPOSED",
                "MALE_BREAST_EXPOSED",
                "BUTTOCKS_EXPOSED" -> "nudity"

                "FEMALE_GENITALIA_COVERED",
                "FEMALE_BREAST_COVERED",
                "BUTTOCKS_COVERED",
                "ANUS_COVERED" -> "suggestive"

                "FACE_FEMALE",
                "FACE_MALE",
                "FEET_EXPOSED",
                "FEET_COVERED",
                "BELLY_EXPOSED",
                "BELLY_COVERED",
                "ARMPITS_EXPOSED",
                "ARMPITS_COVERED" -> "safe"

                else -> "unknown"
            }
        }
    }
}
