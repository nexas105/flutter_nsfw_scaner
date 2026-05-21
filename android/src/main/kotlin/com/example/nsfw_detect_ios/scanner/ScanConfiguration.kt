package com.example.nsfw_detect_ios.scanner

/**
 * Data class parsed from the map that Dart's ScanConfiguration.toChannelMap() sends.
 * All fields have defaults matching Dart defaults.
 */
data class ScanConfiguration(
    val modelId: String = "opennsfw2_coreml",
    val confidenceThreshold: Double = 0.7,
    val maxVideoFrames: Int = 8,
    val videoFrameInterval: Double = 2.0,
    val includeVideos: Boolean = true,
    val includeLivePhotos: Boolean = true,
    val assetIdentifiers: List<String>? = null,
    val resumeFromCheckpoint: Boolean = true,
    val concurrency: Int = 4,
    val detectionConfidenceThreshold: Double = 0.25,
    val iouThreshold: Double = 0.45,
    val skipAlreadyScanned: Boolean = true,
    val forceRescan: Boolean = false,
    val replayCachedResults: Boolean = true,
    val acceleratorDelegate: String? = null,
    /**
     * Native scan mode. `"classification"` (default) routes through
     * [com.example.nsfw_detect_ios.ml.MLEngine]; `"detection"` routes through
     * [com.example.nsfw_detect_ios.ml.MLDetectorEngine]. Wire value comes
     * from Dart `ScanMode.wireValue`.
     */
    val mode: String = "classification",
    /**
     * Optional normalised crop rectangle applied to each decoded bitmap
     * before inference. Coordinates are in `[0..1]` with top-left origin;
     * `null` means use the full image. Cross-platform with iOS' equivalent
     * `roi` arg. Filled by [ScanConfiguration.from].
     */
    val roi: NormalizedRect? = null,
    /**
     * Asset IDs to skip mid-loop (used by the Dart-side moderation gate so
     * the user can drop in-progress assets without restarting the scan).
     */
    val skipAssetIds: List<String>? = null,
    /**
     * If non-null, only assets whose ID is in this set are scanned. Applied
     * AFTER the MediaStore query — so a `startScan` already filtered by
     * `assetIdentifiers` will further intersect with this list.
     */
    val includeOnlyAssetIds: List<String>? = null,
) {
    /** Normalised crop rectangle (0..1, top-left origin). */
    data class NormalizedRect(
        val x: Double,
        val y: Double,
        val width: Double,
        val height: Double,
    ) {
        /** True when the rect covers the whole image (no-op crop). */
        val isFull: Boolean
            get() = x <= 0.0 && y <= 0.0 && width >= 1.0 && height >= 1.0
        /** Quick validity check; ScanSessionTask falls back to full-bitmap when invalid. */
        val isValid: Boolean
            get() = width > 0.0 && height > 0.0 &&
                x in 0.0..1.0 && y in 0.0..1.0 &&
                (x + width) <= 1.0001 && (y + height) <= 1.0001
    }

    companion object {
        fun from(args: Map<*, *>): ScanConfiguration = ScanConfiguration(
            modelId = args["modelId"] as? String ?: "opennsfw2_coreml",
            confidenceThreshold = (args["confidenceThreshold"] as? Double) ?: 0.7,
            maxVideoFrames = (args["maxVideoFrames"] as? Int) ?: 8,
            videoFrameInterval = (args["videoFrameInterval"] as? Double) ?: 2.0,
            includeVideos = (args["includeVideos"] as? Boolean) ?: true,
            includeLivePhotos = (args["includeLivePhotos"] as? Boolean) ?: true,
            assetIdentifiers = (args["assetIdentifiers"] as? List<*>)?.mapNotNull { it as? String },
            resumeFromCheckpoint = (args["resumeFromCheckpoint"] as? Boolean) ?: true,
            concurrency = (args["concurrency"] as? Int) ?: 4,
            detectionConfidenceThreshold = (args["detectionConfidenceThreshold"] as? Double) ?: 0.25,
            iouThreshold = (args["iouThreshold"] as? Double) ?: 0.45,
            skipAlreadyScanned = (args["skipAlreadyScanned"] as? Boolean) ?: true,
            forceRescan = (args["forceRescan"] as? Boolean) ?: false,
            replayCachedResults = (args["replayCachedResults"] as? Boolean) ?: true,
            acceleratorDelegate = args["androidDelegate"] as? String,
            mode = (args["mode"] as? String) ?: "classification",
            roi = parseRoi(args["roi"]),
            skipAssetIds = (args["skipAssetIds"] as? List<*>)?.mapNotNull { it as? String },
            includeOnlyAssetIds = (args["includeOnlyAssetIds"] as? List<*>)?.mapNotNull { it as? String },
        )

        /** Parse `{x, y, width, height}` → [NormalizedRect]; tolerant of nulls/types. */
        fun parseRoi(raw: Any?): NormalizedRect? {
            val map = raw as? Map<*, *> ?: return null
            val x = (map["x"] as? Number)?.toDouble() ?: return null
            val y = (map["y"] as? Number)?.toDouble() ?: return null
            val w = (map["width"] as? Number)?.toDouble() ?: return null
            val h = (map["height"] as? Number)?.toDouble() ?: return null
            return NormalizedRect(x, y, w, h)
        }
    }
}
