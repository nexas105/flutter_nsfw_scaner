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
) {
    /** True if the model needs an online download before it can be used. */
    val requiresDownload: Boolean get() = downloadUrl != null

    /**
     * Whether the model is currently usable.
     *
     * Bundled models are always available. Downloadable models are only
     * available once their resource lives in [ModelDownloadManager.modelsDirectory].
     */
    fun isAvailable(context: Context): Boolean {
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
