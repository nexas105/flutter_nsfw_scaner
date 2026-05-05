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
    val resumeFromCheckpoint: Boolean = false,
    val concurrency: Int = 4,
    val detectionConfidenceThreshold: Double = 0.25,
    val iouThreshold: Double = 0.45,
    val skipAlreadyScanned: Boolean = true,
    val forceRescan: Boolean = false,
    val replayCachedResults: Boolean = true,
    val acceleratorDelegate: String? = null,
) {
    companion object {
        fun from(args: Map<*, *>): ScanConfiguration = ScanConfiguration(
            modelId = args["modelId"] as? String ?: "opennsfw2_coreml",
            confidenceThreshold = (args["confidenceThreshold"] as? Double) ?: 0.7,
            maxVideoFrames = (args["maxVideoFrames"] as? Int) ?: 8,
            videoFrameInterval = (args["videoFrameInterval"] as? Double) ?: 2.0,
            includeVideos = (args["includeVideos"] as? Boolean) ?: true,
            includeLivePhotos = (args["includeLivePhotos"] as? Boolean) ?: true,
            assetIdentifiers = (args["assetIdentifiers"] as? List<*>)?.mapNotNull { it as? String },
            resumeFromCheckpoint = (args["resumeFromCheckpoint"] as? Boolean) ?: false,
            concurrency = (args["concurrency"] as? Int) ?: 4,
            detectionConfidenceThreshold = (args["detectionConfidenceThreshold"] as? Double) ?: 0.25,
            iouThreshold = (args["iouThreshold"] as? Double) ?: 0.45,
            skipAlreadyScanned = (args["skipAlreadyScanned"] as? Boolean) ?: true,
            forceRescan = (args["forceRescan"] as? Boolean) ?: false,
            replayCachedResults = (args["replayCachedResults"] as? Boolean) ?: true,
            acceleratorDelegate = args["androidDelegate"] as? String,
        )
    }
}
