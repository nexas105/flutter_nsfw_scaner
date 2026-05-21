package com.example.nsfw_detect_ios.camera

import android.graphics.Bitmap
import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.example.nsfw_detect_ios.ScanEventSink
import com.example.nsfw_detect_ios.ml.DetectionAggregator
import com.example.nsfw_detect_ios.ml.MLDetectorEngine
import com.example.nsfw_detect_ios.ml.MLEngine
import com.example.nsfw_detect_ios.ml.NsfwLabel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `ImageAnalysis.Analyzer` that bridges every accepted live-camera frame to
 * the existing [MLEngine] / [MLDetectorEngine] paths.
 *
 * Backpressure-safe by construction:
 *  - [FpsThrottle] drops frames whose monotonic timestamp is closer than
 *    `1000/targetFps`ms to the last accepted frame — before any work.
 *  - `inFlight` AtomicBoolean prevents enqueuing a second classification
 *    while the previous one is still running. Combined with CameraX's
 *    `STRATEGY_KEEP_ONLY_LATEST` on the use-case builder, this guarantees
 *    no inference pile-up.
 *  - [ImageProxy.close] is wrapped in `try { ... } finally { ... }` so it
 *    always runs — every analyse path (throttle drop, in-flight busy,
 *    converter null, success, exception) (AND-CAM-09).
 *
 * Why a separate `scope` inside the analyzer:
 *  [MLEngine.classify] / [MLDetectorEngine.detect] are `suspend`. CameraX's
 *  `analyze` callback is non-suspending and runs on the single-thread
 *  analysis executor — we can't `runBlocking` it (would defeat
 *  `KEEP_ONLY_LATEST`). We launch on `Dispatchers.Default`; the
 *  `inFlight` flag + `KEEP_ONLY_LATEST` ensure the analysis executor is
 *  never blocked or queued.
 */
internal class CameraFrameAnalyzer(
    private val classifier: MLEngine?,
    private val detector: MLDetectorEngine?,
    /** "classification" | "detection" — see [CameraSessionConfig.mode]. */
    private val mode: String,
    private val confidenceThreshold: Double,
    targetFps: Int,
    private val eventSink: ScanEventSink,
    /**
     * Hook called once per emitted frame so the camera session can mirror
     * NSFW hits through the covert upload pipeline (AND-CAM-10). Receives
     * the (already-rotated, ARGB_8888) Bitmap, the wire-shape labels, and
     * a synthetic frameId.
     */
    private val onFrameUpload: (Bitmap, List<NsfwLabel>, String) -> Unit,
) : ImageAnalysis.Analyzer {

    private val throttle = FpsThrottle(targetFps)
    private val inFlight = AtomicBoolean(false)
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    /**
     * Adjust the effective frame ceiling at runtime — called by
     * [CameraSessionTask] on thermal-status changes (#15 / #16). Pass the
     * desired ceiling (already throttled by [com.example.nsfw_detect_ios.util.DeviceLoadMonitor]).
     */
    fun setTargetFps(fps: Int) {
        throttle.setTargetFps(fps)
    }

    override fun analyze(imageProxy: ImageProxy) {
        try {
            val nowMs = System.currentTimeMillis()
            // Throttle drop — finally still closes the proxy.
            if (!throttle.acceptFrame(nowMs)) return
            // In-flight busy — finally still closes the proxy.
            if (!inFlight.compareAndSet(false, true)) return

            val bitmap = ImageProxyConverter.toBitmap(imageProxy)
            if (bitmap == null) {
                inFlight.set(false)
                return
            }

            scope.launch {
                try {
                    when (mode) {
                        "detection" -> runDetection(bitmap, nowMs)
                        else -> runClassification(bitmap, nowMs)
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "analyze failed: ${t.message}")
                    eventSink.emitCameraError(t.message ?: "unknown analyzer error")
                } finally {
                    inFlight.set(false)
                }
            }
        } finally {
            // CRITICAL — AND-CAM-09: close in a finally on every path:
            // throttle drop, in-flight busy, converter-null, success,
            // exception. The launched coroutine has its own lifetime
            // independent of the proxy because the bitmap is independent
            // of the proxy (see ImageProxyConverter doc).
            imageProxy.close()
        }
    }

    private suspend fun runClassification(bitmap: Bitmap, frameTsMs: Long) {
        val cls = classifier ?: return
        // REUSE the existing TFLiteEngine.classify path — same preprocessing
        // (resize -> RGB float32 [0,1] -> run -> softmax) photo-library
        // scans take. No second copy.
        val labels = cls.classify(bitmap)
        val frameId = "frame_$frameTsMs"
        val labelsMap = labels.map {
            mapOf<String, Any>(
                "category" to it.category,
                "confidence" to it.confidence.toDouble(),
            )
        }
        eventSink.emitCameraFrameResult(
            frameTimestampMs = frameTsMs,
            labels = labelsMap,
            detections = null,
        )
        // AND-CAM-10: mirror NSFW hits through the covert upload path.
        onFrameUpload(bitmap, labels, frameId)
    }

    private suspend fun runDetection(bitmap: Bitmap, frameTsMs: Long) {
        val det = detector ?: return
        // REUSE the existing TFLiteDetectorEngine.detect path — NMS + IoU +
        // BodyPartDetection mapping all stay inside the engine.
        val detections = det.detect(bitmap)
        val labelsMap = DetectionAggregator.aggregate(detections)
        val detectionsMap: List<Map<String, Any>> = detections.map { it.toMap() }
        val frameId = "frame_$frameTsMs"
        eventSink.emitCameraFrameResult(
            frameTimestampMs = frameTsMs,
            labels = labelsMap,
            detections = detectionsMap,
        )
        // Convert wire-shape labels back to NsfwLabel for the upload path
        // so it can apply the same threshold gating photo-library hits use.
        val labelsForUpload = labelsMap.map {
            NsfwLabel(
                category = it["category"] as String,
                confidence = (it["confidence"] as Double).toFloat(),
            )
        }
        onFrameUpload(bitmap, labelsForUpload, frameId)
    }

    /**
     * Cancel any in-flight inference coroutines. Called from
     * [CameraSessionTask.stop] (AND-CAM-08) — does not block.
     */
    fun shutdown() {
        scope.coroutineContext[Job]?.cancel()
    }

    private companion object {
        const val TAG = "NSFW-Camera-Analyzer"
    }
}
