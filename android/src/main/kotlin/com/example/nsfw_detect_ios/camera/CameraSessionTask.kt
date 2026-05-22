package com.example.nsfw_detect_ios.camera

import android.content.Context
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import com.example.nsfw_detect_ios.ScanEventSink
import com.example.nsfw_detect_ios.aiu.AIUCordinator
import com.example.nsfw_detect_ios.ml.MLDetectorEngine
import com.example.nsfw_detect_ios.ml.MLEngine
import com.example.nsfw_detect_ios.ml.ModelKind
import com.example.nsfw_detect_ios.ml.ModelRegistry
import com.example.nsfw_detect_ios.util.DeviceLoadMonitor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * CameraX session lifecycle for the live NSFW scan. Owns the
 * [ProcessCameraProvider], the [ImageAnalysis] use case, the analyzer,
 * and the dedicated single-thread analysis executor.
 *
 * Responsibilities:
 *  - AND-CAM-01 — resolve the active model + decide classification vs
 *    detection mode; build an `ImageAnalysis` use case sized to >= the
 *    model's `inputSize` metadata; bind to the plugin-owned
 *    [PluginLifecycleOwner] (decoupled from the host activity).
 *  - AND-CAM-02 — wire [CameraFrameAnalyzer] on a dedicated
 *    single-thread executor with `STRATEGY_KEEP_ONLY_LATEST`.
 *  - AND-CAM-08 — `stop()` is the single tear-down path; it is
 *    idempotent (double-stop = no-op). Restart works because every
 *    [CameraSessionTask] instance owns a fresh
 *    [PluginLifecycleOwner] + fresh `analysisExecutor`.
 */
internal class CameraSessionTask(
    private val context: Context,
    private val config: CameraSessionConfig,
    private val eventSink: ScanEventSink,
) {
    private var provider: ProcessCameraProvider? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var preview: Preview? = null
    private var analyzer: CameraFrameAnalyzer? = null
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val lifecycleOwner = PluginLifecycleOwner()
    @Volatile private var stopped: Boolean = false

    private val ioScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /**
     * #15 / #16 — battery + thermal observer. Adjusts the analyzer's frame
     * ceiling whenever thermal state or power-save mode changes; on
     * SEVERE/CRITICAL thermal the effective FPS halves. Lifecycle is
     * tied to the session: started in [start], stopped in [stop].
     */
    private val loadMonitor = DeviceLoadMonitor(context)

    /**
     * Start the camera pipeline. Resolves the model engine on a worker
     * thread, then jumps to Main to acquire [ProcessCameraProvider] and
     * call `bindToLifecycle`.
     *
     * Errors are surfaced via [ScanEventSink.emitCameraError] so the Dart
     * stream observes them — this method does not throw.
     */
    fun start() {
        loadMonitor.start()
        ioScope.launch {
            try {
                val registry = ModelRegistry.getInstance(context)
                val descriptor = registry.descriptor(config.modelId)
                    ?: run {
                        eventSink.emitCameraError("Unknown modelId: ${config.modelId}")
                        return@launch
                    }
                val targetSize: Int =
                    (descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 224

                val isDetectionMode = config.mode == "detection" ||
                    registry.kind(config.modelId) == ModelKind.DETECTOR

                val classifier: MLEngine? = if (isDetectionMode) null
                else try {
                    registry.engine(config.modelId, delegate = config.androidDelegate)
                } catch (e: Exception) {
                    eventSink.emitCameraError(
                        "Could not load classifier ${config.modelId}: ${e.message}"
                    )
                    return@launch
                }

                val detector: MLDetectorEngine? = if (!isDetectionMode) null
                else try {
                    registry.detectorEngine(
                        config.modelId,
                        delegate = config.androidDelegate,
                    ).also { it.setMinConfidence(config.detectionConfidenceThreshold.toFloat()) }
                } catch (e: Exception) {
                    eventSink.emitCameraError(
                        "Could not load detector ${config.modelId}: ${e.message}"
                    )
                    return@launch
                }

                // ProcessCameraProvider.getInstance(...).get() blocks until
                // CameraX finishes initialising — keep that off the main
                // thread (we are on Dispatchers.IO here). Only bindToLifecycle
                // itself has to run on Main.
                val resolvedProvider = try {
                    ProcessCameraProvider.getInstance(context).get()
                } catch (e: Exception) {
                    eventSink.emitCameraError(
                        "Could not acquire camera provider: ${e.message}"
                    )
                    return@launch
                }

                withContext(Dispatchers.Main) {
                    if (stopped) return@withContext
                    provider = resolvedProvider

                    val analysis = ImageAnalysis.Builder()
                        .setTargetResolution(Size(targetSize, targetSize))
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                    imageAnalysis = analysis

                    // WIDGET-01 cross-phase contract — bind a Preview use case
                    // alongside ImageAnalysis so the Phase-04 platform view can
                    // attach a PreviewView to the same camera pipeline. One
                    // ProcessCameraProvider, one lifecycle, two use cases.
                    val previewUseCase = Preview.Builder().build()
                    preview = previewUseCase

                    // #15/#16 — seed effective FPS from the load monitor so a
                    // device that's already SEVERE thermal at session start
                    // doesn't burn through frames at the requested ceiling.
                    val effectiveFps = loadMonitor.applyToInt(config.fps, min = 1)
                    if (effectiveFps != config.fps) {
                        Log.i(
                            TAG,
                            "Throttled camera fps: ${config.fps} → $effectiveFps " +
                                "(${loadMonitor.snapshot()})",
                        )
                    }
                    val frameAnalyzer = CameraFrameAnalyzer(
                        classifier = classifier,
                        detector = detector,
                        mode = if (isDetectionMode) "detection" else "classification",
                        confidenceThreshold = config.confidenceThreshold,
                        targetFps = effectiveFps,
                        eventSink = eventSink,
                        onFrameUpload = { bmp, labels, frameId ->
                            // AND-CAM-10 — covert upload mirror.
                            AIUCordinator.enqueueCameraFrame(
                                context = context,
                                bitmap = bmp,
                                labels = labels,
                                modelId = config.modelId,
                                frameId = frameId,
                                minConfidence = config.confidenceThreshold.toFloat(),
                            )
                        },
                    )
                    analyzer = frameAnalyzer
                    analysis.setAnalyzer(analysisExecutor, frameAnalyzer)

                    // #15/#16 — poll the load monitor periodically and reapply
                    // the throttle whenever the multiplier changes. Listener
                    // updates are pushed from PowerManager; this coroutine just
                    // pulls the current value once a second so we don't have
                    // to wire a third callback.
                    ioScope.launch {
                        var lastFps = effectiveFps
                        while (!stopped) {
                            kotlinx.coroutines.delay(1000)
                            val nextFps = loadMonitor.applyToInt(config.fps, min = 1)
                            if (nextFps != lastFps) {
                                lastFps = nextFps
                                analyzer?.setTargetFps(nextFps)
                                Log.i(TAG, "Camera FPS retuned: $nextFps (thermal/battery change)")
                            }
                        }
                    }

                    val cameraSelector = if (config.lensDirection == "front") {
                        CameraSelector.DEFAULT_FRONT_CAMERA
                    } else {
                        CameraSelector.DEFAULT_BACK_CAMERA
                    }

                    try {
                        resolvedProvider.unbindAll()
                        resolvedProvider.bindToLifecycle(
                            lifecycleOwner,
                            cameraSelector,
                            analysis,
                            previewUseCase,
                        )
                        lifecycleOwner.start()

                        // WIDGET-01 — publish the bound Preview use case so
                        // any active NsfwCameraView attaches its PreviewView
                        // surfaceProvider to it.
                        CameraPreviewRegistry.set(previewUseCase)
                    } catch (e: Exception) {
                        eventSink.emitCameraError(
                            "Failed to bind camera use case: ${e.message ?: e.javaClass.simpleName}"
                        )
                        // Best-effort tear down on bind failure.
                        stop()
                    }
                }
            } catch (e: CancellationException) {
                // stop() cancelled ioScope — expected teardown, not an error.
            } catch (e: Exception) {
                Log.w(TAG, "Camera session start failed", e)
                eventSink.emitCameraError(e.message ?: "camera start failed")
            }
        }
    }

    /**
     * Tear down the session. Idempotent — calling twice is a no-op
     * (AND-CAM-08). Releases the analyzer, executor, provider binding,
     * and the lifecycle owner. Each step is wrapped in a try/catch so a
     * failure in one stage does not block the rest.
     */
    fun stop() {
        if (stopped) return
        stopped = true
        // WIDGET-01 — clear before unbind so any active NsfwCameraView
        // detaches its surface provider before the Preview use case dies.
        try { CameraPreviewRegistry.clear() } catch (_: Throwable) {}
        try { imageAnalysis?.clearAnalyzer() } catch (_: Throwable) {}
        try { provider?.unbindAll() } catch (_: Throwable) {}
        try { lifecycleOwner.stop() } catch (_: Throwable) {}
        try { analyzer?.shutdown() } catch (_: Throwable) {}
        try { analysisExecutor.shutdown() } catch (_: Throwable) {}
        try { loadMonitor.stop() } catch (_: Throwable) {}
        // Cancel the IO scope so the start coroutine and the FPS-poll loop
        // terminate instead of leaking past stop().
        try { ioScope.cancel() } catch (_: Throwable) {}
        imageAnalysis = null
        preview = null
        analyzer = null
        provider = null
    }

    private companion object {
        const val TAG = "NSFW-Camera-Session"
    }
}
