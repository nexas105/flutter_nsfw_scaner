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

    class ModelCorrupt(val modelId: String, val reason: String) :
        MLEngineError(
            "ML model corrupt: $modelId — $reason. " +
                "If you are using the bundled OpenNSFW2 asset, replace " +
                "android/src/main/assets/open_nsfw2.tflite with the real " +
                "TFLite flatbuffer (see README → \"Get the model\"). For " +
                "downloaded models, delete the cached artifact and re-download."
        )
}

/**
 * Validates that [bytes] looks like a TFLite FlatBuffer model.
 *
 * Real TFLite files carry the FlatBuffer file-identifier `TFL3` at bytes 4..7
 * (per `schema.fbs`). The placeholder ASCII files we ship as bundled
 * stand-ins (and any HTML error page that sneaks past a broken CDN) will not
 * pass this check. Cheap to call — caller still owns the buffer.
 *
 * @throws MLEngineError.ModelCorrupt with a hint when the bytes are clearly
 *   not a TFLite model. Conservative: tiny size or missing magic.
 */
internal fun validateTFLiteBytes(modelId: String, bytes: ByteArray) {
    // 8 bytes minimum for any FlatBuffer (4-byte root-table offset + 4-byte
    // file-identifier). Real models are always at least several KB; the
    // 619-byte UTF-8 placeholder slips through a length-only check, so we
    // also enforce the magic below.
    if (bytes.size < 8) {
        throw MLEngineError.ModelCorrupt(
            modelId,
            "file is only ${bytes.size} bytes (expected a TFLite flatbuffer)"
        )
    }
    val hasMagic = bytes[4] == 'T'.code.toByte() &&
        bytes[5] == 'F'.code.toByte() &&
        bytes[6] == 'L'.code.toByte() &&
        bytes[7] == '3'.code.toByte()
    if (!hasMagic) {
        // Hint at the placeholder case so devs don't have to hex-dump.
        val isPlaceholder = bytes.size < 4096 &&
            bytes.take(11).toByteArray().toString(Charsets.US_ASCII) == "PLACEHOLDER"
        val reason = if (isPlaceholder) {
            "file is a text placeholder, not a TFLite flatbuffer"
        } else {
            "missing TFLite 'TFL3' file-identifier at offset 4"
        }
        throw MLEngineError.ModelCorrupt(modelId, reason)
    }
}
