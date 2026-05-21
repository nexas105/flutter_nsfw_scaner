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
 * TFLite object-detection engine for YOLOv8-style NudeNet models.
 *
 * Expected output tensor (single output, raw ultralytics YOLOv8 export):
 *   - shape `[1, 22, A]` where `22 = 4 (cx, cy, w, h in input pixels) + 18
 *     class scores in [0, 1]`, and `A` is the total anchor count across
 *     detection scales (8400 for input 640).
 *
 * Per-anchor processing: argmax class over channels 4..21, drop anchors
 * below [minConfidence], convert `(cx, cy, w, h)` → normalised
 * `(x, y, width, height)` with top-left origin, then run class-aware
 * NMS at `IOU_THRESHOLD = 0.45`. The final list mirrors the iOS path
 * via Vision's built-in NMS.
 *
 * Pendant to `ios/Classes/ml/CoreMLDetectorEngine.swift`.
 */
class TFLiteDetectorEngine(
    private val context: Context,
    override val descriptor: ModelDescriptorNative,
) : MLDetectorEngine {

    private var interpreter: Interpreter? = null
    private var preferredDelegate: String? = null
    private var actualLoadedDelegate: String? = null

    private val runMutex = Mutex()
    private val loadMutex = Mutex()

    private val inputSize: Int =
        (descriptor.metadata["inputSize"] as? Number)?.toInt() ?: DEFAULT_INPUT_SIZE

    private var minConfidence: Float = 0.25f

    override val loadedDelegate: String?
        get() = actualLoadedDelegate

    override fun setPreferredAcceleratorDelegate(delegate: String?) {
        if (interpreter != null && actualLoadedDelegate == delegate) return
        preferredDelegate = delegate
    }

    override fun setMinConfidence(minConfidence: Float) {
        this.minConfidence = maxOf(0f, minConfidence)
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
        // tell when we silently fell back to CPU.
        actualLoadedDelegate = when (preferredDelegate?.lowercase()) {
            null -> "cpu"
            else -> if (delegateActuallyApplied) preferredDelegate else "cpu"
        }
        Log.i(TAG, "Loaded detector ${descriptor.id} (requested=${preferredDelegate ?: "cpu"}, actual=$actualLoadedDelegate)")
    }

    override fun unload() {
        try { interpreter?.close() } catch (_: Throwable) {}
        interpreter = null
        actualLoadedDelegate = null
    }

    override suspend fun detect(bitmap: Bitmap): List<BodyPartDetection> {
        if (interpreter == null) load()
        val interp = interpreter ?: throw MLEngineError.NotLoaded()

        // Hold runMutex across the whole pipeline — TFLite Interpreter is
        // not thread-safe, and Bitmap.createScaledBitmap leaks native pixel
        // memory if two coroutines race the same input. Centralising under
        // one lock also lets us reliably recycle the scaled copy.
        return runMutex.withLock {
            val resized: Bitmap
            val ownsResized: Boolean
            if (bitmap.width == inputSize && bitmap.height == inputSize) {
                resized = bitmap
                ownsResized = false
            } else {
                resized = Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)
                ownsResized = resized !== bitmap
            }

            try {
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

                // Read output shape from the interpreter — A varies with input size
                // (8400 for 640, 2100 for 320). Allocate exactly to avoid over-reads.
                val outShape = interp.getOutputTensor(0).shape()  // [1, 22, A]
                require(outShape.size == 3 && outShape[1] == CHANNELS) {
                    "Unexpected detector output shape ${outShape.contentToString()}; expected [1, $CHANNELS, A]"
                }
                val numAnchors = outShape[2]
                val output = Array(1) { Array(CHANNELS) { FloatArray(numAnchors) } }
                interp.run(inputBuffer, output)
                parseAndNms(output[0], numAnchors)
            } finally {
                if (ownsResized && !resized.isRecycled) resized.recycle()
            }
        }
    }

    /**
     * Parse YOLOv8 raw output and apply class-aware NMS. Per-anchor layout:
     * `[cx, cy, w, h, score_0, …, score_17]` with bbox in input-pixel coords
     * and scores already sigmoid-activated.
     */
    private fun parseAndNms(out: Array<FloatArray>, numAnchors: Int): List<BodyPartDetection> {
        val candidates = ArrayList<Box>(64)
        val invSize = 1f / inputSize
        for (i in 0 until numAnchors) {
            // Argmax over class scores (channels 4..21).
            var bestScore = 0f
            var bestClass = -1
            for (c in 0 until NUM_CLASSES) {
                val s = out[4 + c][i]
                if (s > bestScore) {
                    bestScore = s
                    bestClass = c
                }
            }
            if (bestClass < 0 || bestScore < minConfidence) continue

            val cx = out[0][i] * invSize
            val cy = out[1][i] * invSize
            val w  = out[2][i] * invSize
            val h  = out[3][i] * invSize
            val xMin = (cx - w * 0.5f).coerceIn(0f, 1f)
            val yMin = (cy - h * 0.5f).coerceIn(0f, 1f)
            val xMax = (cx + w * 0.5f).coerceIn(0f, 1f)
            val yMax = (cy + h * 0.5f).coerceIn(0f, 1f)
            if (xMax <= xMin || yMax <= yMin) continue
            candidates.add(Box(xMin, yMin, xMax, yMax, bestScore, bestClass))
        }
        if (candidates.isEmpty()) return emptyList()

        // Class-aware NMS — sort by score desc, suppress overlaps within same class.
        candidates.sortByDescending { it.score }
        val kept = ArrayList<Box>(candidates.size)
        outer@ for (cand in candidates) {
            for (k in kept) {
                if (k.classIndex != cand.classIndex) continue
                if (iou(cand, k) > IOU_THRESHOLD) continue@outer
            }
            kept.add(cand)
            if (kept.size >= MAX_DETECTIONS) break
        }

        val results = ArrayList<BodyPartDetection>(kept.size)
        for (b in kept) {
            val label = NUDENET_LABELS.getOrNull(b.classIndex) ?: continue
            results.add(
                BodyPartDetection(
                    label = label,
                    confidence = b.score,
                    x = b.xMin,
                    y = b.yMin,
                    width  = (b.xMax - b.xMin).coerceAtLeast(0f),
                    height = (b.yMax - b.yMin).coerceAtLeast(0f),
                    aggregatedCategory = BodyPartDetection.aggregateCategoryFor(label),
                )
            )
        }
        return results
    }

    private fun iou(a: Box, b: Box): Float {
        val interLeft   = maxOf(a.xMin, b.xMin)
        val interTop    = maxOf(a.yMin, b.yMin)
        val interRight  = minOf(a.xMax, b.xMax)
        val interBottom = minOf(a.yMax, b.yMax)
        val interW = (interRight - interLeft).coerceAtLeast(0f)
        val interH = (interBottom - interTop).coerceAtLeast(0f)
        val inter  = interW * interH
        if (inter <= 0f) return 0f
        val areaA = (a.xMax - a.xMin) * (a.yMax - a.yMin)
        val areaB = (b.xMax - b.xMin) * (b.yMax - b.yMin)
        val union = areaA + areaB - inter
        return if (union > 0f) inter / union else 0f
    }

    // MARK: - Asset loading (mirrors TFLiteEngine.loadModelBuffer)

    private fun loadModelBuffer(): ByteBuffer {
        // Custom-registered detector — bypass the bundle / download search
        // and read directly from the sandbox-validated absolute path.
        descriptor.customAssetPath?.let { custom ->
            val file = File(custom)
            if (!file.isFile) throw MLEngineError.ModelNotFound(descriptor.id)
            val bytes = file.readBytes()
            validateTFLiteBytes(descriptor.id, bytes)
            return ByteBuffer.allocateDirect(bytes.size).apply {
                order(ByteOrder.nativeOrder())
                put(bytes)
                rewind()
            }
        }

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

        val resourceName = descriptor.bundleResourceName ?: descriptor.id
        val bytes: ByteArray = try {
            context.assets.openFd("$resourceName.tflite").use { afd ->
                afd.createInputStream().use { it.readBytes() }
            }
        } catch (_: Throwable) {
            throw MLEngineError.ModelNotFound(descriptor.id)
        }
        validateTFLiteBytes(descriptor.id, bytes)
        return ByteBuffer.allocateDirect(bytes.size).apply {
            order(ByteOrder.nativeOrder())
            put(bytes)
            rewind()
        }
    }

    private fun resolveTFLiteFile(path: File): File? {
        if (path.isFile) return path
        if (path.isDirectory) {
            return path.walkTopDown().firstOrNull { it.isFile && it.name.endsWith(".tflite") }
        }
        return null
    }

    /**
     * Try every `candidates` class until one succeeds. Returns `true` when
     * a delegate was applied, `false` if all candidates failed (caller can
     * then mark [actualLoadedDelegate] = "cpu" for transparency — #20).
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

    /** Internal representation during NMS — normalised top-left coords. */
    private data class Box(
        val xMin: Float, val yMin: Float, val xMax: Float, val yMax: Float,
        val score: Float, val classIndex: Int,
    )

    private companion object {
        const val TAG = "NSFW-TFLiteDetector"
        const val DEFAULT_INPUT_SIZE = 640
        const val NUM_CLASSES = 18
        const val CHANNELS = 4 + NUM_CLASSES   // YOLOv8: 4 bbox + 18 classes
        const val IOU_THRESHOLD = 0.45f
        const val MAX_DETECTIONS = 100

        /**
         * Canonical NudeNet 18-class label table. Order MUST match the
         * ultralytics export's `names` dict. Verified against the v3.4-weights
         * 640m.pt checkpoint at conversion time.
         */
        val NUDENET_LABELS = listOf(
            "FEMALE_GENITALIA_COVERED",
            "FACE_FEMALE",
            "BUTTOCKS_EXPOSED",
            "FEMALE_BREAST_EXPOSED",
            "FEMALE_GENITALIA_EXPOSED",
            "MALE_BREAST_EXPOSED",
            "ANUS_EXPOSED",
            "FEET_EXPOSED",
            "BELLY_COVERED",
            "FEET_COVERED",
            "ARMPITS_COVERED",
            "ARMPITS_EXPOSED",
            "FACE_MALE",
            "BELLY_EXPOSED",
            "MALE_GENITALIA_EXPOSED",
            "ANUS_COVERED",
            "FEMALE_BREAST_COVERED",
            "BUTTOCKS_COVERED",
        )
    }
}
