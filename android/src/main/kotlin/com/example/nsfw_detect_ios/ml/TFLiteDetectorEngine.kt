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
 * TFLite object-detection engine for SSD-style NudeNet models.
 *
 * Expected output tensors (standard SSD MobileNet layout — 4 outputs):
 *   - `output_locations` shape `[1, N, 4]` boxes `(y_min, x_min, y_max, x_max)`, normalised
 *   - `output_classes`   shape `[1, N]`     class index as float
 *   - `output_scores`    shape `[1, N]`     confidence in `[0, 1]`
 *   - `num_detections`   shape `[1]`        number of valid detections
 *
 * The class-index → label table is the canonical 18-class NudeNet vocabulary
 * (see [NUDENET_LABELS]). Boxes below [minConfidence] are dropped. Coordinates
 * are converted from `(y_min, x_min, y_max, x_max)` to `(x, y, width, height)`
 * with origin top-left for parity with the iOS detector.
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
    /** Maximum N (boxes) per tensor — depends on model export, but 100 is the SSD norm. */
    private val maxDetections: Int =
        (descriptor.metadata["maxDetections"] as? Number)?.toInt() ?: DEFAULT_MAX_DETECTIONS

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
        Log.i(TAG, "Loaded detector ${descriptor.id} (delegate=${actualLoadedDelegate ?: "cpu"})")
    }

    override fun unload() {
        try { interpreter?.close() } catch (_: Throwable) {}
        interpreter = null
        actualLoadedDelegate = null
    }

    override suspend fun detect(bitmap: Bitmap): List<BodyPartDetection> {
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

        // SSD-style 4-output layout. Allocate the maximum and let the model fill in
        // the actual count via num_detections.
        val locations = Array(1) { Array(maxDetections) { FloatArray(4) } }
        val classes   = Array(1) { FloatArray(maxDetections) }
        val scores    = Array(1) { FloatArray(maxDetections) }
        val numDet    = FloatArray(1)

        val outputs: MutableMap<Int, Any> = mutableMapOf(
            0 to locations,
            1 to classes,
            2 to scores,
            3 to numDet,
        )

        runMutex.withLock {
            interp.runForMultipleInputsOutputs(arrayOf<Any>(inputBuffer), outputs)
        }

        val n = numDet[0].toInt().coerceIn(0, maxDetections)
        val results = ArrayList<BodyPartDetection>(n)
        for (i in 0 until n) {
            val score = scores[0][i]
            if (score < minConfidence) continue

            val classIndex = classes[0][i].toInt()
            val label = NUDENET_LABELS.getOrNull(classIndex) ?: continue

            val yMin = locations[0][i][0].coerceIn(0f, 1f)
            val xMin = locations[0][i][1].coerceIn(0f, 1f)
            val yMax = locations[0][i][2].coerceIn(0f, 1f)
            val xMax = locations[0][i][3].coerceIn(0f, 1f)
            val width  = (xMax - xMin).coerceAtLeast(0f)
            val height = (yMax - yMin).coerceAtLeast(0f)

            val agg = BodyPartDetection.aggregateCategoryFor(label)
            results.add(
                BodyPartDetection(
                    label = label,
                    confidence = score,
                    x = xMin,
                    y = yMin,
                    width = width,
                    height = height,
                    aggregatedCategory = agg,
                )
            )
        }
        return results
    }

    // MARK: - Asset loading (mirrors TFLiteEngine.loadModelBuffer)

    private fun loadModelBuffer(): ByteBuffer {
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

        val resourceName = descriptor.bundleResourceName ?: descriptor.id
        try {
            context.assets.openFd("$resourceName.tflite").use { afd ->
                afd.createInputStream().use { input ->
                    val bytes = input.readBytes()
                    return ByteBuffer.allocateDirect(bytes.size).apply {
                        order(ByteOrder.nativeOrder())
                        put(bytes)
                        rewind()
                    }
                }
            }
        } catch (t: Throwable) {
            throw MLEngineError.ModelNotFound(descriptor.id)
        }
    }

    private fun resolveTFLiteFile(path: File): File? {
        if (path.isFile) return path
        if (path.isDirectory) {
            return path.walkTopDown().firstOrNull { it.isFile && it.name.endsWith(".tflite") }
        }
        return null
    }

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
        const val TAG = "NSFW-TFLiteDetector"
        const val DEFAULT_INPUT_SIZE = 320
        const val DEFAULT_MAX_DETECTIONS = 100

        /**
         * Canonical NudeNet 18-class label table. Order MUST match the model's
         * class-index output. The standard NudeNet TFLite export uses this
         * order; if a custom model uses a different one, override via
         * `descriptor.metadata["labels"]` is a future improvement (not in
         * Phase B scope — the user's converted model is expected to use this
         * canonical order).
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
