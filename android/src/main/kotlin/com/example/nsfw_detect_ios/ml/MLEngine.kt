package com.example.nsfw_detect_ios.ml

import android.graphics.Bitmap

/**
 * Common surface for all ML inference engines. Lets the scanner swap
 * TFLite / ONNX / future runtimes without touching the call sites.
 *
 * Mirrors the `MLEngine` Swift protocol in `ios/Classes/ml/MLEngine.swift`.
 */
interface MLEngine {
    val descriptor: ModelDescriptorNative

    /** Load the model into memory. Idempotent. */
    suspend fun load()

    /** Free model resources. Safe to call multiple times. */
    fun unload()

    /** Run inference on one bitmap. Implementations must be safe to call concurrently. */
    suspend fun classify(bitmap: Bitmap): List<NsfwLabel>

    /**
     * Run inference on a batch of bitmaps. Default implementation falls back to
     * serial [classify] calls so engines don't have to override.
     */
    suspend fun classifyBatch(bitmaps: List<Bitmap>): List<List<NsfwLabel>> {
        val results = ArrayList<List<NsfwLabel>>(bitmaps.size)
        for (bmp in bitmaps) results.add(classify(bmp))
        return results
    }

    /**
     * Hint the engine which accelerator delegate to wire up at [load] time.
     * Pass null for CPU. Engines that don't expose delegate selection treat
     * this as a no-op.
     *
     * Pendant to iOS' `setPreferredComputeUnits`.
     */
    fun setPreferredAcceleratorDelegate(delegate: String?) { /* no-op */ }

    /** Delegate string the currently loaded model was built with (null until loaded). */
    val loadedDelegate: String?
        get() = null
}

/** Errors raised by [MLEngine] implementations and the registry. */
sealed class MLEngineError(message: String) : Exception(message) {
    class ModelNotFound(val modelId: String) :
        MLEngineError("ML model not found: $modelId")

    class ModelNotDownloaded(val modelId: String) :
        MLEngineError("ML model not downloaded: $modelId. Download it first.")

    class NotLoaded :
        MLEngineError("ML model not loaded. Call load() first.")

    class BatchSizeMismatch(val expected: Int, val got: Int) :
        MLEngineError("Batch output count mismatch: expected $expected, got $got.")

    class InvalidOutput :
        MLEngineError("ML model returned invalid output.")
}
