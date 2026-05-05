package com.example.nsfw_detect_ios.ml

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import com.google.ai.edge.litert.Interpreter
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Generalized TFLite inference engine. The model is selected via
 * [ModelDescriptorNative] (bundled or downloaded), input size and output
 * shape come from descriptor metadata, and category mapping is applied per
 * model id.
 *
 * Pendant to `ios/Classes/ml/CoreMLEngine.swift`.
 */
class TFLiteEngine(
    private val context: Context,
    override val descriptor: ModelDescriptorNative,
) : MLEngine {

    private var interpreter: Interpreter? = null
    private var preferredDelegate: String? = null
    private var actualLoadedDelegate: String? = null

    /** Coarse-grained lock around `Interpreter.run` — TFLite interpreters are not thread-safe. */
    private val runMutex = Mutex()
    private val loadMutex = Mutex()

    private val inputSize: Int =
        (descriptor.metadata["inputSize"] as? Number)?.toInt() ?: DEFAULT_INPUT_SIZE
    private val outputSize: Int =
        (descriptor.metadata["outputSize"] as? Number)?.toInt() ?: DEFAULT_OUTPUT_SIZE

    override val loadedDelegate: String?
        get() = actualLoadedDelegate

    override fun setPreferredAcceleratorDelegate(delegate: String?) {
        // If already loaded with this delegate, do nothing. Otherwise the next
        // load() call will pick it up.
        if (interpreter != null && actualLoadedDelegate == delegate) return
        preferredDelegate = delegate
    }

    override suspend fun load() = loadMutex.withLock {
        if (interpreter != null) return@withLock
        val buffer = loadModelBuffer()
        val options = Interpreter.Options()
        when (preferredDelegate?.lowercase()) {
            "gpu" -> tryAddDelegate(
                options,
                listOf(
                    "com.google.ai.edge.litert.gpu.GpuDelegate",
                    "org.tensorflow.lite.gpu.GpuDelegate",
                ),
                "GPU",
            )
            "nnapi" -> tryAddDelegate(
                options,
                listOf(
                    "com.google.ai.edge.litert.nnapi.NnApiDelegate",
                    "org.tensorflow.lite.nnapi.NnApiDelegate",
                ),
                "NNAPI",
            )
        }
        interpreter = Interpreter(buffer, options)
        actualLoadedDelegate = preferredDelegate
        Log.i(TAG, "Loaded model ${descriptor.id} (delegate=${actualLoadedDelegate ?: "cpu"})")
    }

    override fun unload() {
        try {
            interpreter?.close()
        } catch (_: Throwable) {}
        interpreter = null
        actualLoadedDelegate = null
    }

    /** Backwards-compatible alias used by older call sites. */
    fun close() = unload()

    override suspend fun classify(bitmap: Bitmap): List<NsfwLabel> {
        if (interpreter == null) load()
        val interp = interpreter ?: throw MLEngineError.NotLoaded()

        val resized = if (bitmap.width == inputSize && bitmap.height == inputSize) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)
        }

        val inputBuffer = ByteBuffer.allocateDirect(1 * inputSize * inputSize * 3 * 4).apply {
            order(ByteOrder.nativeOrder())
        }
        for (y in 0 until inputSize) {
            for (x in 0 until inputSize) {
                val pixel = resized.getPixel(x, y)
                inputBuffer.putFloat(Color.red(pixel) / 255f)
                inputBuffer.putFloat(Color.green(pixel) / 255f)
                inputBuffer.putFloat(Color.blue(pixel) / 255f)
            }
        }
        inputBuffer.rewind()

        val outputArray = Array(1) { FloatArray(outputSize) }
        runMutex.withLock {
            interp.run(inputBuffer, outputArray)
        }
        return parseOutput(outputArray[0])
    }

    // MARK: - Output parsing

    private fun parseOutput(raw: FloatArray): List<NsfwLabel> {
        val n = raw.size
        if (n == 2) {
            // OpenNSFW2 / Falconsai-style: [safe, nudity].
            return listOf(
                NsfwLabel("safe", raw[0]),
                NsfwLabel("nudity", raw[1]),
            ).sortedByDescending { it.confidence }
        }

        if (n >= 5 && descriptor.id == ModelIds.ADAMCODD) {
            return parseAdamCoddOutput(raw)
        }

        if (n >= 5) {
            // Generic 5-class layout: [safe, suggestive, nudity, explicitNudity, unknown].
            val cats = listOf("safe", "suggestive", "nudity", "explicitNudity", "unknown")
            return cats.indices.map { NsfwLabel(cats[it], raw[it]) }
                .sortedByDescending { it.confidence }
        }

        if (n > 0) {
            val safe = raw[0]
            val nsfw = if (n > 1) raw[n - 1] else (1f - safe)
            return listOf(
                NsfwLabel("safe", safe),
                NsfwLabel("nudity", nsfw),
            ).sortedByDescending { it.confidence }
        }

        return emptyList()
    }

    /**
     * AdamCodd ViT (5 logits): [drawings, hentai, neutral, porn, sexy].
     * Collapses source labels onto the plugin's canonical categories — identical
     * to Swift's `parseAdamCoddMultiArrayOutput`.
     */
    private fun parseAdamCoddOutput(raw: FloatArray): List<NsfwLabel> {
        val drawings = raw[0]
        val hentai = raw[1]
        val neutral = raw[2]
        val porn = raw[3]
        val sexy = raw[4]

        val safe = maxOf(drawings, neutral)
        val suggestive = sexy
        val nudity = hentai
        val explicit = porn

        return listOf(
            NsfwLabel("safe", safe),
            NsfwLabel("suggestive", suggestive),
            NsfwLabel("nudity", nudity),
            NsfwLabel("explicitNudity", explicit),
        ).sortedByDescending { it.confidence }
    }

    // MARK: - Asset loading

    private fun loadModelBuffer(): ByteBuffer {
        // Downloaded model takes precedence — descriptor said it requires download.
        if (descriptor.requiresDownload) {
            val resourceName = descriptor.bundleResourceName
                ?: throw MLEngineError.ModelNotFound(descriptor.id)
            val file = ModelDownloadManager.getInstance(context).localFile(resourceName)
                ?: throw MLEngineError.ModelNotDownloaded(descriptor.id)
            val tfliteFile = resolveTFLiteFile(file)
                ?: throw MLEngineError.ModelNotFound(descriptor.id)
            val bytes = tfliteFile.readBytes()
            return ByteBuffer.allocateDirect(bytes.size).apply {
                order(ByteOrder.nativeOrder())
                put(bytes)
                rewind()
            }
        }

        // Bundled in assets/. Asset filename derived from bundleResourceName.
        // Compatibility shim: the legacy bundled file is `open_nsfw2.tflite`
        // (no underscore before "2"), but the iOS-aligned descriptor uses
        // `open_nsfw_2` as the resource name. Map both spellings.
        val resourceName = descriptor.bundleResourceName ?: descriptor.id
        val candidates = buildList {
            add("$resourceName.tflite")
            if (resourceName == "open_nsfw_2") add("open_nsfw2.tflite")
        }

        for (assetName in candidates) {
            try {
                context.assets.openFd(assetName).use { afd ->
                    afd.createInputStream().use { input ->
                        val bytes = input.readBytes()
                        return ByteBuffer.allocateDirect(bytes.size).apply {
                            order(ByteOrder.nativeOrder())
                            put(bytes)
                            rewind()
                        }
                    }
                }
            } catch (_: Throwable) {
                // Try next candidate
            }
        }
        throw MLEngineError.ModelNotFound(descriptor.id)
    }

    /** When the downloaded artifact is a directory, look for a .tflite inside. */
    private fun resolveTFLiteFile(path: File): File? {
        if (path.isFile) return path
        if (path.isDirectory) {
            return path.walkTopDown().firstOrNull { it.isFile && it.name.endsWith(".tflite") }
        }
        return null
    }

    // MARK: - Delegate reflection

    private fun tryAddDelegate(
        options: Interpreter.Options,
        candidates: List<String>,
        tag: String,
    ) {
        for (className in candidates) {
            try {
                val delegateCls = Class.forName(className)
                val delegate = delegateCls.getDeclaredConstructor().newInstance()
                val method = options.javaClass.methods.firstOrNull {
                    it.name == "addDelegate" && it.parameterTypes.size == 1
                } ?: continue
                method.invoke(options, delegate)
                Log.i(TAG, "$tag delegate enabled via $className")
                return
            } catch (t: Throwable) {
                Log.w(TAG, "$tag delegate $className unavailable: ${t.message}")
            }
        }
        Log.w(TAG, "$tag delegate could not be loaded — falling back to CPU")
    }

    private companion object {
        const val TAG = "NSFW-TFLite"
        const val DEFAULT_INPUT_SIZE = 224
        const val DEFAULT_OUTPUT_SIZE = 2
    }
}
