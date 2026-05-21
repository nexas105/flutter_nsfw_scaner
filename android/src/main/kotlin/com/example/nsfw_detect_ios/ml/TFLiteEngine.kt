package com.example.nsfw_detect_ios.ml

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.util.Log
import org.tensorflow.lite.Interpreter
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
        var delegateActuallyApplied = false
        when (preferredDelegate?.lowercase()) {
            "gpu" -> {
                delegateActuallyApplied = tryAddDelegate(
                    options,
                    listOf(
                        "org.tensorflow.lite.gpu.GpuDelegate",
                        "com.google.ai.edge.litert.gpu.GpuDelegate",
                    ),
                    "GPU",
                )
            }
            "nnapi" -> {
                delegateActuallyApplied = tryAddDelegate(
                    options,
                    listOf(
                        "org.tensorflow.lite.nnapi.NnApiDelegate",
                        "com.google.ai.edge.litert.nnapi.NnApiDelegate",
                    ),
                    "NNAPI",
                )
            }
        }
        interpreter = Interpreter(buffer, options)
        // #20: surface the *actual* delegate that was applied so callers can
        // tell when we silently fell back to CPU. `loadedDelegate` returns
        // "cpu" instead of (say) "gpu" if the GPU delegate JAR is missing
        // from the host app.
        actualLoadedDelegate = when (preferredDelegate?.lowercase()) {
            null -> "cpu"
            else -> if (delegateActuallyApplied) preferredDelegate else "cpu"
        }
        Log.i(TAG, "Loaded model ${descriptor.id} (requested=${preferredDelegate ?: "cpu"}, actual=$actualLoadedDelegate)")
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
            // All currently supported TFLite models are 2-class:
            //   - OpenNSFW2:   [safe, nudity]
            //   - Falconsai:   [normal, nsfw]   (semantic: [safe, nudity])
            //   - AdamCodd:    [sfw, nsfw]      (semantic: [safe, nudity])
            //
            // For Falconsai/AdamCodd, the converted .tflite has softmax baked
            // into the graph (see tools/convert_models.py), so raw[0] and
            // raw[1] are already probabilities in [0, 1].
            return listOf(
                NsfwLabel("safe", raw[0]),
                NsfwLabel("nudity", raw[1]),
            ).sortedByDescending { it.confidence }
        }

        // Defensive fallback for unexpected output shapes — collapse to a
        // 2-class view by treating raw[0] as safe and the last logit as nsfw.
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
            validateTFLiteBytes(descriptor.id, bytes)
            return ByteBuffer.allocateDirect(bytes.size).apply {
                order(ByteOrder.nativeOrder())
                put(bytes)
                rewind()
            }
        }

        // Bundled in assets/. Asset filename derived from bundleResourceName.
        // OpenNSFW2 has been flipped to download-on-demand (the historical
        // bundled file was always a UTF-8 placeholder), so this path now
        // only fires for custom descriptors a host app registers itself.
        val resourceName = descriptor.bundleResourceName ?: descriptor.id
        val candidates = listOf("$resourceName.tflite")

        var lastError: Throwable? = null
        for (assetName in candidates) {
            val bytes: ByteArray = try {
                context.assets.openFd(assetName).use { afd ->
                    afd.createInputStream().use { it.readBytes() }
                }
            } catch (t: Throwable) {
                lastError = t
                continue
            }
            // Validate before allocating direct buffer — a placeholder asset
            // would otherwise propagate as an opaque TFLite runtime crash
            // ("did not get magic number") later in Interpreter(buffer, …).
            validateTFLiteBytes(descriptor.id, bytes)
            return ByteBuffer.allocateDirect(bytes.size).apply {
                order(ByteOrder.nativeOrder())
                put(bytes)
                rewind()
            }
        }
        Log.w(TAG, "No bundled TFLite asset found for ${descriptor.id}; last error: ${lastError?.message}")
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

    /**
     * Try every `candidates` class until one succeeds. Returns `true` when
     * a delegate was applied, `false` if all candidates failed (caller can
     * then mark [actualLoadedDelegate] = "cpu" for transparency — #20).
     *
     * Failure path stops swallowing: every candidate failure logs at WARN
     * with the underlying exception, and a final WARN summarises the
     * fallback so users have something to grep in their logs.
     */
    private fun tryAddDelegate(
        options: Interpreter.Options,
        candidates: List<String>,
        tag: String,
    ): Boolean {
        for (className in candidates) {
            try {
                val delegateCls = Class.forName(className)
                val delegate = delegateCls.getDeclaredConstructor().newInstance()
                val method = options.javaClass.methods.firstOrNull {
                    it.name == "addDelegate" && it.parameterTypes.size == 1
                } ?: continue
                method.invoke(options, delegate)
                Log.i(TAG, "$tag delegate enabled via $className")
                return true
            } catch (t: Throwable) {
                Log.w(TAG, "Falling back to CPU: $tag delegate $className unavailable — ${t.message}", t)
            }
        }
        Log.w(TAG, "Falling back to CPU: $tag delegate could not be loaded for ${descriptor.id}")
        return false
    }

    private companion object {
        const val TAG = "NSFW-TFLite"
        const val DEFAULT_INPUT_SIZE = 224
        const val DEFAULT_OUTPUT_SIZE = 2
    }
}
