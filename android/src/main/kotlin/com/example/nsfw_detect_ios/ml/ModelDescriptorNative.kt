package com.example.nsfw_detect_ios.ml

import android.content.Context

/**
 * Value-type description of a registered ML model.
 *
 * Mirrors `ios/Classes/ml/ModelDescriptorNative.swift`. The map produced by
 * [toMap] crosses the method channel and MUST keep iOS-identical keys.
 */
data class ModelDescriptorNative(
    val id: String,
    val displayName: String,
    val description: String? = null,
    val version: String? = null,
    /** Resource name without extension (e.g. "OpenNSFW2"). */
    val bundleResourceName: String? = null,
    val metadata: Map<String, Any> = emptyMap(),
    /** If null, the model is bundled in the APK. Otherwise download required. */
    val downloadUrl: String? = null,
    /** Approximate download size in bytes (0 = unknown / bundled). */
    val downloadSizeBytes: Long = 0,
    /**
     * Optional SHA-256 of the downloaded archive (lowercase hex). When set,
     * [ModelDownloadManager] verifies the downloaded bytes match before
     * extraction — mismatch deletes the temp file and throws. Pin this for
     * any URL the integrator does not fully control.
     */
    val expectedSha256: String? = null,
    /**
     * Absolute filesystem path to a custom-registered .tflite file. When
     * set, [TFLiteEngine] / [TFLiteDetectorEngine] load from here instead
     * of searching assets / download dir. Always nil for built-in models.
     * Always inside the host app sandbox — see
     * `ScanMethodHandler.registerModel` for the path-validation policy.
     */
    val customAssetPath: String? = null,
) {
    /** True if the model needs an online download before it can be used. */
    val requiresDownload: Boolean get() = downloadUrl != null

    /**
     * Whether the model is currently usable.
     *
     * Custom-registered models are available iff the file exists. Bundled
     * models are always available. Downloadable models are only available
     * once their resource lives in [ModelDownloadManager.modelsDirectory].
     */
    fun isAvailable(context: Context): Boolean {
        if (customAssetPath != null) return java.io.File(customAssetPath).exists()
        if (downloadUrl == null) return true
        val name = bundleResourceName ?: return false
        return ModelDownloadManager.getInstance(context).isDownloaded(name)
    }

    /**
     * Method-channel representation. Keys are kept in lock-step with iOS'
     * `toDictionary()` — Dart code on the other side parses by exact key name.
     */
    fun toMap(context: Context): Map<String, Any> {
        val map = mutableMapOf<String, Any>(
            "id" to id,
            "displayName" to displayName,
            "metadata" to metadata,
            "requiresDownload" to requiresDownload,
            "isDownloaded" to isAvailable(context),
        )
        description?.let { map["description"] = it }
        version?.let { map["version"] = it }
        if (downloadSizeBytes > 0) map["downloadSizeBytes"] = downloadSizeBytes
        downloadUrl?.let { map["downloadUrl"] = it }
        return map
    }
}
