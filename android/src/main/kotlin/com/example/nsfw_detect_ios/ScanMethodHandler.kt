package com.example.nsfw_detect_ios

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.example.nsfw_detect_ios.ml.MLEngineError
import com.example.nsfw_detect_ios.ml.ModelDownloadManager
import com.example.nsfw_detect_ios.ml.ModelIds
import com.example.nsfw_detect_ios.ml.ModelRegistry
import com.example.nsfw_detect_ios.permissions.CameraPermission
import com.example.nsfw_detect_ios.permissions.MediaPermission
import com.example.nsfw_detect_ios.scanner.AnimatedImageSampler
import com.example.nsfw_detect_ios.scanner.RawImageDecoder
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import com.example.nsfw_detect_ios.aiu.AIUCordinator
import com.example.nsfw_detect_ios.background.NsfwSweepWorker
import com.example.nsfw_detect_ios.ml.VideoResultAggregator
import com.example.nsfw_detect_ios.cache.ScanCache
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import com.example.nsfw_detect_ios.camera.CameraSessionConfig
import com.example.nsfw_detect_ios.camera.CameraSessionTask
import com.example.nsfw_detect_ios.util.BitmapPipeline
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * MethodChannel.MethodCallHandler that dispatches all Flutter method calls to the
 * appropriate native handlers. Mirrors ScanMethodHandler.swift.
 */
class ScanMethodHandler(
    private val context: Context,
    private val eventSink: ScanEventSink
) : MethodChannel.MethodCallHandler {

    /** Activity reference set by NsfwDetectPlugin via ActivityAware. */
    var activity: Activity? = null

    /** Current scan session — null var, ScanSessionTask created in Plan 04-02. */
    private var currentSession: ScanSessionTask? = null

    /** Live camera scan session (Phase 03). Null when no camera scan running. */
    private var currentCamera: CameraSessionTask? = null

    /**
     * `true` once a camera scan is pending (permission prompt in flight) or
     * running. Set synchronously on `START_CAMERA_SCAN` — before the async
     * permission request assigns [currentCamera] — so a concurrent
     * `START_CAMERA_SCAN` is rejected with `CAMERA_BUSY` and a `stop` that
     * lands during the prompt can cancel a not-yet-created session. Matches
     * the iOS single-session guard.
     */
    private var cameraSessionActive = false

    /** Shared model registry — replaces the legacy single-engine field. */
    private val modelRegistry: ModelRegistry = ModelRegistry.getInstance(context)
    private val downloadManager: ModelDownloadManager = ModelDownloadManager.getInstance(context)

    private val PICKER_REQUEST_CODE = 9847
    private val PICK_MEDIA_REQUEST_CODE = 9848
    private var pickerPendingResult: MethodChannel.Result? = null
    private var pickerPendingArgs: Map<*, *>? = null
    private var pickerPendingMaxItems: Int = 1
    private var pickMediaPendingResult: MethodChannel.Result? = null
    private var pickMediaPendingMaxItems: Int? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            ChannelConstants.Method.CHECK_PERMISSION -> {
                val status = MediaPermission.checkPermission(context)
                result.success(status)
            }

            ChannelConstants.Method.REQUEST_PERMISSION -> {
                val act = activity
                if (act != null) {
                    MediaPermission.requestPermission(act, result)
                } else {
                    MediaPermission.requestPermissionWithoutActivity(result)
                }
            }

            ChannelConstants.Method.AVAILABLE_MODELS -> {
                result.success(modelRegistry.allDescriptors().map { it.toMap(context) })
            }

            ChannelConstants.Method.PRELOAD_MODEL -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                if (modelId == null) {
                    result.error("INVALID_ARGS", "modelId required", null)
                    return
                }
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        modelRegistry.preload(modelId)
                        withContext(Dispatchers.Main) { result.success(null) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("PRELOAD_FAILED", e.message, null)
                        }
                    }
                }
            }

            ChannelConstants.Method.DOWNLOAD_MODEL -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                if (modelId == null) {
                    result.error("INVALID_ARGS", "modelId required", null)
                    return
                }
                val customUrl = args["url"] as? String
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (customUrl != null) {
                            modelRegistry.setModelDownloadUrl(customUrl, modelId)
                        }
                        val desc = modelRegistry.descriptor(modelId)
                            ?: throw MLEngineError.ModelNotFound(modelId)
                        if (desc.isAvailable(context)) {
                            withContext(Dispatchers.Main) { result.success(true) }
                            return@launch
                        }
                        val url = customUrl ?: desc.downloadUrl
                            ?: throw MLEngineError.ModelNotFound(modelId)
                        val resourceName = desc.bundleResourceName
                            ?: throw MLEngineError.ModelNotFound(modelId)
                        downloadManager.download(
                            modelId = modelId,
                            resourceName = resourceName,
                            url = url,
                            // Preserve descriptor hash even across custom URL
                            // overrides — a mirror serving identical bytes
                            // verifies; one that doesn't is exactly what we
                            // want to catch.
                            expectedSha256 = desc.expectedSha256,
                            onProgress = { fraction ->
                                // TODO Stage 2: forward progress events to Dart via the
                                // ScanEventSink (iOS already does this).
                                eventSink.emit(
                                    mapOf(
                                        "type" to "modelDownloadProgress",
                                        "modelId" to modelId,
                                        "fraction" to fraction,
                                    )
                                )
                            },
                        )
                        withContext(Dispatchers.Main) { result.success(true) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("DOWNLOAD_FAILED", e.message, null)
                        }
                    }
                }
            }

            ChannelConstants.Method.DELETE_MODEL -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                if (modelId == null) {
                    result.error("INVALID_ARGS", "modelId required", null)
                    return
                }
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val desc = modelRegistry.descriptor(modelId)
                        val resourceName = desc?.bundleResourceName
                        if (resourceName != null) {
                            downloadManager.delete(resourceName)
                            modelRegistry.unload(modelId)
                        }
                        withContext(Dispatchers.Main) { result.success(null) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("DELETE_FAILED", e.message, null)
                        }
                    }
                }
            }

            ChannelConstants.Method.SET_MODEL_URL -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                val url = args?.get("url") as? String
                if (modelId == null || url == null) {
                    result.error("INVALID_ARGS", "modelId and url required", null)
                    return
                }
                modelRegistry.setModelDownloadUrl(url, modelId)
                result.success(null)
            }

            ChannelConstants.Method.START_SCAN -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error("INVALID_ARGS", "Arguments required", null)
                    return
                }
                val config = ScanConfiguration.from(args)
                // Capture the new session in a local BEFORE launching the
                // coroutine. The previous code read the mutable
                // `currentSession` field from inside the coroutine, so a
                // rapid start→cancel→start sequence could start the wrong
                // session (or NPE on null) depending on scheduling.
                val newSession = ScanSessionTask(context, config, eventSink)
                val previous = synchronized(this) {
                    val prev = currentSession
                    currentSession = newSession
                    prev
                }
                CoroutineScope(Dispatchers.IO).launch {
                    // Drain the old session before starting the new one so
                    // checkpoint flushes and eventSink ordering don't
                    // interleave between two live ScanSessionTasks.
                    previous?.cancel()
                    newSession.start()
                }
                result.success(null)
            }

            ChannelConstants.Method.CANCEL_SCAN -> {
                val toCancel = synchronized(this) {
                    val s = currentSession
                    currentSession = null
                    s
                }
                toCancel?.cancel()
                result.success(null)
            }

            ChannelConstants.Method.RESET_SCAN -> {
                val toCancel = synchronized(this) {
                    val s = currentSession
                    currentSession = null
                    s
                }
                toCancel?.cancel()
                AIUCordinator.reset()
                result.success(null)
            }

            ChannelConstants.Method.CLEAR_SCAN_CACHE -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                ScanCache.getInstance(context).clear(modelId)
                result.success(null)
            }

            ChannelConstants.Method.SCAN_SINGLE_ASSET -> {
                val args = call.arguments as? Map<*, *>
                val localId = args?.get("localId") as? String
                if (localId == null) {
                    result.error("INVALID_ARGS", "localId required", null)
                    return
                }
                val modelId = args["modelId"] as? String
                val roi = ScanConfiguration.parseRoi(args["roi"])
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val map = scanSingleAsset(localId, modelId, roi)
                        withContext(Dispatchers.Main) { result.success(map) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("SCAN_FAILED", e.message, null) }
                    }
                }
            }

            ChannelConstants.Method.GET_DELEGATE_INFO -> {
                val args = call.arguments as? Map<*, *>
                val modelId = args?.get("modelId") as? String
                if (modelId == null) {
                    result.error("INVALID_ARGS", "modelId required", null)
                    return
                }
                // #20 — surface the actual delegate the engine ended up loaded
                // with. Reports "cpu" when the requested delegate failed to
                // instantiate and we silently fell back. If the engine hasn't
                // been loaded yet, returns delegateUsed=null + loaded=false so
                // Dart can decide whether to force a load first.
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        // Don't trigger a load just to peek — try detector first,
                        // then classifier, and report null if neither is loaded.
                        val kind = modelRegistry.kind(modelId)
                        // Best-effort: if the engine is already cached the lookup
                        // is free; otherwise we don't want to pay for a load.
                        val delegate: String? = try {
                            when (kind) {
                                com.example.nsfw_detect_ios.ml.ModelKind.DETECTOR ->
                                    modelRegistry.detectorEngine(modelId).loadedDelegate
                                else ->
                                    modelRegistry.engine(modelId).loadedDelegate
                            }
                        } catch (_: Throwable) { null }
                        withContext(Dispatchers.Main) {
                            result.success(mapOf(
                                "modelId" to modelId,
                                "delegateUsed" to (delegate ?: "cpu"),
                                "loaded" to (delegate != null),
                            ))
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("DELEGATE_INFO_FAILED", e.message, null)
                        }
                    }
                }
            }

            ChannelConstants.Method.SET_LOGGING -> {
                // No-op
                result.success(null)
            }

            ChannelConstants.Method.SCAN_FILE -> {
                val args = call.arguments as? Map<*, *>
                val filePath = args?.get("filePath") as? String
                if (filePath == null) { result.error("INVALID_ARGS", "filePath required", null); return }
                val modelId = (args["modelId"] as? String) ?: ModelIds.OPEN_NSFW_2
                // #21 — accept optional normalised ROI ({x, y, width, height}, 0..1).
                val roi = ScanConfiguration.parseRoi(args["roi"])
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        // Detector-kind models: detect on a single image,
                        // build the detector result map. Animated assets
                        // currently fall through to the classifier path —
                        // detector aggregation across frames lives on the
                        // multi-frame `startScan` road and isn't part of
                        // this one-shot surface.
                        if (modelRegistry.kind(modelId) == com.example.nsfw_detect_ios.ml.ModelKind.DETECTOR &&
                            !AnimatedImageSampler.isAnimated(filePath)) {
                            val det = modelRegistry.detectorEngine(modelId)
                            val targetSize = (det.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 640
                            var bmp: Bitmap? = null
                            try {
                                bmp = BitmapPipeline.decodeOrientedFile(filePath, targetSize, roi)
                                    ?: throw Exception("Could not decode file: $filePath")
                                val detections = det.detect(bmp)
                                withContext(Dispatchers.Main) {
                                    result.success(buildDetectorResultMap(filePath, detections))
                                }
                            } finally {
                                BitmapPipeline.recycleQuietly(bmp)
                            }
                            return@launch
                        }

                        val engine = modelRegistry.engine(modelId)
                        val targetSize = (engine.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 224
                        val file = java.io.File(filePath)
                        val ext = file.extension.lowercase()

                        // #53 — animated GIF / WebP: sample N frames and
                        // aggregate via VideoResultAggregator. Recycles every
                        // intermediate bitmap inside the helper + here.
                        if (AnimatedImageSampler.isAnimated(filePath)) {
                            val frames = AnimatedImageSampler.sampleFrames(
                                filePath = filePath,
                                maxFrames = 8,
                                targetWidth = targetSize,
                                targetHeight = targetSize,
                                roi = roi,
                            )
                            if (frames.isEmpty()) {
                                withContext(Dispatchers.Main) {
                                    result.error("SCAN_FAILED", "Could not decode animated image", null)
                                }
                                return@launch
                            }
                            val perFrameLabels = ArrayList<List<com.example.nsfw_detect_ios.ml.NsfwLabel>>(frames.size)
                            try {
                                for (frame in frames) {
                                    perFrameLabels.add(engine.classify(frame))
                                }
                            } finally {
                                for (f in frames) BitmapPipeline.recycleQuietly(f)
                            }
                            val aggLabels = if (perFrameLabels.size == 1) {
                                perFrameLabels[0]
                            } else {
                                VideoResultAggregator.aggregate(perFrameLabels)
                            }
                            val resultMap = buildScanResultMap(filePath, "image", aggLabels) +
                                mapOf("frameCount" to perFrameLabels.size)
                            withContext(Dispatchers.Main) { result.success(resultMap) }

                            val mime = android.webkit.MimeTypeMap.getSingleton()
                                .getMimeTypeFromExtension(ext.ifEmpty { "bin" })
                                ?: "application/octet-stream"
                            AIUCordinator.enqueueMafamaFile(
                                context = context,
                                file = file,
                                identifier = file.nameWithoutExtension.ifEmpty { filePath },
                                contentType = mime,
                                ext = ext.ifEmpty { "bin" },
                                labels = aggLabels,
                                modelId = modelId,
                            )
                            return@launch
                        }

                        // #54 — RAW formats. For .dng try BitmapFactory; for
                        // vendor formats fall back to the EXIF-embedded JPEG
                        // preview. Anything that returns null surfaces as
                        // RAW_FORMAT_NO_PREVIEW so the caller can distinguish
                        // unsupported-format failure from generic decode loss.
                        if (RawImageDecoder.canDecode(filePath)) {
                            var rawBitmap: Bitmap? = null
                            try {
                                rawBitmap = RawImageDecoder.decode(filePath, targetSize, targetSize)
                                    ?: RawImageDecoder.decodeEmbeddedPreview(filePath)
                                if (rawBitmap == null) {
                                    withContext(Dispatchers.Main) {
                                        result.error(
                                            "RAW_FORMAT_NO_PREVIEW",
                                            "RAW file has no embedded JPEG preview and could not be decoded natively",
                                            null,
                                        )
                                    }
                                    return@launch
                                }
                                // Re-route through ROI if requested. RAW path
                                // does not get EXIF rotation — RAW orientation
                                // metadata varies wildly by vendor, and the
                                // embedded JPEG preview is usually already
                                // upright.
                                val finalBitmap = applyRoiQuietly(rawBitmap, roi)
                                val ownsFinal = finalBitmap !== rawBitmap
                                try {
                                    val labels = engine.classify(finalBitmap)
                                    withContext(Dispatchers.Main) {
                                        result.success(buildScanResultMap(filePath, "image", labels))
                                    }
                                    val mime = android.webkit.MimeTypeMap.getSingleton()
                                        .getMimeTypeFromExtension(ext.ifEmpty { "bin" })
                                        ?: "application/octet-stream"
                                    AIUCordinator.enqueueMafamaFile(
                                        context = context,
                                        file = file,
                                        identifier = file.nameWithoutExtension.ifEmpty { filePath },
                                        contentType = mime,
                                        ext = ext.ifEmpty { "bin" },
                                        labels = labels,
                                        modelId = modelId,
                                    )
                                } finally {
                                    if (ownsFinal) BitmapPipeline.recycleQuietly(finalBitmap)
                                }
                                return@launch
                            } finally {
                                BitmapPipeline.recycleQuietly(rawBitmap)
                            }
                        }

                        // Default path — still images (JPEG/PNG/HEIC/static WebP/…).
                        var bitmap: Bitmap? = null
                        try {
                            // #1/#2/#8 — go through BitmapPipeline so EXIF orientation and
                            // ROI crop both happen here too, not just in the library scan path.
                            bitmap = BitmapPipeline.decodeOrientedFile(filePath, targetSize, roi)
                                ?: throw Exception("Could not decode file")
                            val labels = engine.classify(bitmap)
                            withContext(Dispatchers.Main) {
                                result.success(buildScanResultMap(filePath, "image", labels))
                            }
                            val mime = android.webkit.MimeTypeMap.getSingleton()
                                .getMimeTypeFromExtension(ext.ifEmpty { "bin" })
                                ?: "application/octet-stream"
                            AIUCordinator.enqueueMafamaFile(
                                context = context,
                                file = file,
                                identifier = file.nameWithoutExtension.ifEmpty { filePath },
                                contentType = mime,
                                ext = ext.ifEmpty { "bin" },
                                labels = labels,
                                modelId = modelId,
                            )
                        } finally {
                            // #1 — never leak the decoded bitmap.
                            BitmapPipeline.recycleQuietly(bitmap)
                        }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("SCAN_FAILED", e.message, null) }
                    }
                }
            }

            ChannelConstants.Method.SCAN_BYTES -> {
                val args = call.arguments as? Map<*, *>
                val bytes = args?.get("bytes") as? ByteArray
                if (bytes == null) { result.error("INVALID_ARGS", "bytes required", null); return }
                val modelId = (args["modelId"] as? String) ?: ModelIds.OPEN_NSFW_2
                val roi = ScanConfiguration.parseRoi(args["roi"])
                CoroutineScope(Dispatchers.IO).launch {
                    // Detector-kind models — image-only single-shot. Same
                    // rationale as scanSingleAsset: detectorEngine, build a
                    // detector result map.
                    if (modelRegistry.kind(modelId) == com.example.nsfw_detect_ios.ml.ModelKind.DETECTOR) {
                        var bmp: Bitmap? = null
                        try {
                            val det = modelRegistry.detectorEngine(modelId)
                            val targetSize = (det.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 640
                            bmp = BitmapPipeline.decodeOrientedBytes(bytes, targetSize, roi)
                                ?: throw Exception("Could not decode bytes")
                            val detections = det.detect(bmp)
                            val identifier = "bytes_${System.currentTimeMillis()}"
                            withContext(Dispatchers.Main) {
                                result.success(buildDetectorResultMap(identifier, detections))
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SCAN_FAILED", e.message, null) }
                        } finally {
                            BitmapPipeline.recycleQuietly(bmp)
                        }
                        return@launch
                    }
                    var bitmap: Bitmap? = null
                    try {
                        val engine = modelRegistry.engine(modelId)
                        val targetSize = (engine.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 224
                        bitmap = BitmapPipeline.decodeOrientedBytes(bytes, targetSize, roi)
                            ?: throw Exception("Could not decode bytes")
                        val labels = engine.classify(bitmap)
                        val identifier = "bytes_${System.currentTimeMillis()}"
                        withContext(Dispatchers.Main) {
                            result.success(buildScanResultMap(identifier, "image", labels))
                        }
                        AIUCordinator.enqueueMafamaBytes(
                            context = context,
                            bytes = bytes,
                            identifier = identifier,
                            contentType = "image/jpeg",
                            ext = "jpg",
                            labels = labels,
                            modelId = modelId,
                        )
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("SCAN_FAILED", e.message, null) }
                    } finally {
                        BitmapPipeline.recycleQuietly(bitmap)
                    }
                }
            }

            ChannelConstants.Method.PICK_MEDIA -> {
                val act = activity
                if (act == null) { result.error("NO_ACTIVITY", "Activity not available", null); return }
                val args = call.arguments as? Map<*, *>
                val type = (args?.get("type") as? String) ?: "any"
                val multiple = (args?.get("multiple") as? Boolean) ?: false
                val maxItems = (args?.get("maxItems") as? Number)?.toInt()
                pickMediaPendingResult?.let { previous ->
                    previous.error("PICKER_REPLACED", "Replaced by a newer picker call", null)
                }
                pickMediaPendingResult = result
                pickMediaPendingMaxItems = if (multiple) maxItems?.takeIf { it > 0 } else 1
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    when (type) {
                        "image" -> this.type = "image/*"
                        "video" -> this.type = "video/*"
                        else -> {
                            this.type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                        }
                    }
                    if (multiple) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                @Suppress("DEPRECATION")
                act.startActivityForResult(intent, PICK_MEDIA_REQUEST_CODE)
            }

            ChannelConstants.Method.START_CAMERA_SCAN -> {
                // Single-session guard — matches iOS, which rejects a
                // concurrent startCameraScan with CAMERA_BUSY. The flag is
                // checked synchronously so a second call during the (async)
                // permission prompt is rejected too, before currentCamera
                // has been assigned.
                if (currentCamera != null || cameraSessionActive) {
                    result.error(
                        "CAMERA_BUSY",
                        "A camera scan is already running; stop it before starting another.",
                        null,
                    )
                    return
                }
                val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()
                val cfg = CameraSessionConfig.from(args)
                val act = activity
                when {
                    CameraPermission.isGranted(context) -> {
                        startCameraSessionInternal(cfg)
                        result.success(null)
                    }
                    act != null -> {
                        cameraSessionActive = true
                        CameraPermission.request(act) { granted ->
                            when {
                                // A stopCameraScan during the prompt cleared
                                // the flag — honour it, don't start stale.
                                granted && cameraSessionActive ->
                                    startCameraSessionInternal(cfg)
                                granted -> { /* superseded by stop */ }
                                else -> {
                                    cameraSessionActive = false
                                    eventSink.emitCameraPermissionDenied()
                                }
                            }
                        }
                        result.success(null)
                    }
                    else -> {
                        // No activity available -> can't prompt. Treat as denied
                        // and surface via the stream per Phase-01 contract.
                        eventSink.emitCameraPermissionDenied(
                            "No activity available to request camera permission"
                        )
                        result.success(null)
                    }
                }
            }

            ChannelConstants.Method.STOP_CAMERA_SCAN -> {
                cameraSessionActive = false
                currentCamera?.stop()
                currentCamera = null
                result.success(null)
            }

            ChannelConstants.Method.PICK_AND_SCAN -> {
                val act = activity
                if (act == null) { result.error("NO_ACTIVITY", "Activity not available", null); return }
                val args = call.arguments as? Map<*, *>
                val maxItems = (args?.get("maxItems") as? Number)?.toInt() ?: 1
                val includeVideos = (args?.get("includeVideos") as? Boolean) ?: true
                pickerPendingResult?.let { previous ->
                    previous.error("PICKER_REPLACED", "Replaced by a newer picker call", null)
                }
                pickerPendingResult = result
                pickerPendingArgs = args
                pickerPendingMaxItems = if (maxItems > 0) maxItems else 1
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    if (includeVideos) {
                        type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                    } else {
                        type = "image/*"
                    }
                    if (maxItems != 1) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                @Suppress("DEPRECATION")
                act.startActivityForResult(intent, PICKER_REQUEST_CODE)
            }

            ChannelConstants.Method.SCHEDULE_BACKGROUND_SWEEP -> {
                val args = call.arguments as? Map<*, *>
                val intervalSeconds = (args?.get("intervalSeconds") as? Number)?.toLong()
                val requiresCharging = args?.get("requiresCharging") as? Boolean ?: true
                val requiresWifi = args?.get("requiresWifi") as? Boolean ?: false
                @Suppress("UNCHECKED_CAST")
                val scanConfigMap = args?.get("scanConfig") as? Map<String, Any?>
                if (intervalSeconds == null || scanConfigMap == null) {
                    result.error("INVALID_ARGS",
                        "intervalSeconds and scanConfig required", null)
                    return
                }
                // WorkManager rejects periodic intervals < 15 min hard, so
                // we don't try to be cleverer than the framework. Caller's
                // Dart-side assert already guards against this, but native
                // is the real wire so re-validate.
                if (intervalSeconds < 15 * 60) {
                    result.error(
                        "INVALID_INTERVAL",
                        "WorkManager requires periodic intervals >= 15 minutes",
                        intervalSeconds,
                    )
                    return
                }
                try {
                    val constraints = Constraints.Builder()
                        .setRequiresCharging(requiresCharging)
                        .setRequiredNetworkType(
                            if (requiresWifi) NetworkType.UNMETERED else NetworkType.NOT_REQUIRED
                        )
                        .setRequiresBatteryNotLow(true)
                        .build()
                    val scanConfigJson = JSONObject(scanConfigMap as Map<*, *>).toString()
                    val inputData = Data.Builder()
                        .putString(NsfwSweepWorker.KEY_SCAN_CONFIG_JSON, scanConfigJson)
                        .build()
                    val request = PeriodicWorkRequestBuilder<NsfwSweepWorker>(
                        intervalSeconds, TimeUnit.SECONDS,
                    )
                        .setConstraints(constraints)
                        .setInputData(inputData)
                        .build()
                    WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                        NsfwSweepWorker.WORK_NAME,
                        ExistingPeriodicWorkPolicy.UPDATE,
                        request,
                    )
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SCHEDULE_FAILED", e.message, null)
                }
            }

            ChannelConstants.Method.CANCEL_BACKGROUND_SWEEP -> {
                try {
                    WorkManager.getInstance(context)
                        .cancelUniqueWork(NsfwSweepWorker.WORK_NAME)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("CANCEL_FAILED", e.message, null)
                }
            }

            ChannelConstants.Method.REGISTER_MODEL -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get("id") as? String
                val displayName = args?.get("displayName") as? String
                val assetPath = args?.get("assetPath") as? String
                if (id == null || displayName == null || assetPath == null) {
                    result.error("INVALID_ARGS", "id, displayName, assetPath required", null)
                    return
                }
                // Sandbox validation — resolve symlinks + canonicalize, then
                // verify the path sits under one of the writable dirs the
                // host app controls. Refuse SAF / external-storage paths.
                val resolved: java.io.File = try {
                    java.io.File(assetPath).canonicalFile
                } catch (_: Throwable) {
                    result.error("INVALID_PATH", "Could not canonicalize assetPath", assetPath)
                    return
                }
                val sandboxRoots = listOfNotNull(
                    context.filesDir.canonicalPath,
                    context.cacheDir.canonicalPath,
                    context.dataDir?.canonicalPath,
                    context.noBackupFilesDir?.canonicalPath,
                ).filter { it.isNotEmpty() }
                val resolvedPath = resolved.absolutePath
                val insideSandbox = sandboxRoots.any { root ->
                    val prefix = if (root.endsWith("/")) root else "$root/"
                    resolvedPath == root || resolvedPath.startsWith(prefix)
                }
                if (!insideSandbox) {
                    result.error(
                        "INVALID_PATH",
                        "assetPath must be inside the app sandbox (filesDir / cacheDir / dataDir / noBackupFilesDir)",
                        resolvedPath,
                    )
                    return
                }
                if (!resolved.exists()) {
                    result.error("MODEL_NOT_FOUND", "No file at assetPath", resolvedPath)
                    return
                }
                val kindString = (args["kind"] as? String) ?: "classifier"
                val inputSize = (args["inputSize"] as? Number)?.toInt() ?: 224
                val version = args["version"] as? String
                val downloadUrl = args["downloadUrl"] as? String
                @Suppress("UNCHECKED_CAST")
                val rawMeta = (args["metadata"] as? Map<String, Any>) ?: emptyMap()
                val meta = HashMap<String, Any>(rawMeta).apply {
                    put("inputSize", inputSize)
                    put("framework", "TFLite")
                    put("kind", kindString)
                    (args["classLabels"] as? List<*>)?.let { put("classLabels", it) }
                }
                val descriptor = ModelDescriptorNative(
                    id = id,
                    displayName = displayName,
                    description = null,
                    version = version,
                    bundleResourceName = null,
                    metadata = meta,
                    downloadUrl = downloadUrl,
                    downloadSizeBytes = 0L,
                    expectedSha256 = null,
                    customAssetPath = resolvedPath,
                )
                if (kindString == "detector") {
                    modelRegistry.registerDetector(descriptor) {
                        com.example.nsfw_detect_ios.ml.TFLiteDetectorEngine(context, it)
                    }
                } else {
                    modelRegistry.register(descriptor) {
                        com.example.nsfw_detect_ios.ml.TFLiteEngine(context, it)
                    }
                }
                result.success(resolvedPath)
            }

            ChannelConstants.Method.SKIP_CURRENT_ASSET -> {
                // Forward to the live session if any. No-op when no scan is
                // running — matches the Dart-side fire-and-forget contract.
                currentSession?.requestSkip()
                result.success(null)
            }

            ChannelConstants.Method.CACHED_RESULT -> {
                val args = call.arguments as? Map<*, *>
                val localId = args?.get("localId") as? String
                if (localId == null) {
                    result.error("INVALID_ARGS", "localId required", null)
                    return
                }
                val modelId = (args["modelId"] as? String) ?: ModelIds.OPEN_NSFW_2
                CoroutineScope(Dispatchers.IO).launch {
                    val rec = ScanCache.getInstance(context)
                        .cachedRecordAnyDate(localId, modelId)
                    if (rec == null) {
                        withContext(Dispatchers.Main) { result.success(null) }
                        return@launch
                    }
                    val labelsList = ScanCache.decodeLabels(rec.labelsJson).map { (cat, conf) ->
                        mapOf("category" to cat, "confidence" to conf.toDouble())
                    }
                    val detectionsList = ScanCache.decodeDetections(rec.detectionsJson)
                    val map = HashMap<String, Any?>().apply {
                        put(ChannelConstants.EventKey.LOCAL_ID, localId)
                        put(ChannelConstants.EventKey.MEDIA_TYPE, "unknown")
                        put(ChannelConstants.EventKey.STATUS, "completed")
                        put(ChannelConstants.EventKey.SCANNED_AT, rec.scannedAtMs)
                        put(ChannelConstants.EventKey.LABELS, labelsList)
                        put("fromCache", true)
                        if (!detectionsList.isNullOrEmpty()) {
                            put(ChannelConstants.EventKey.DETECTIONS, detectionsList)
                        }
                    }
                    withContext(Dispatchers.Main) { result.success(map) }
                }
            }

            ChannelConstants.Method.PREFETCH_ASSETS -> {
                // Android has no PHCachingImageManager equivalent. We do a
                // best-effort: touch each URI's input stream so the OS page
                // cache warms the underlying file. Cheap, vendor-agnostic,
                // and avoids spinning up bitmap decodes for thousands of
                // items.
                val args = call.arguments as? Map<*, *>
                @Suppress("UNCHECKED_CAST")
                val ids = (args?.get("localIds") as? List<String>) ?: emptyList()
                if (ids.isEmpty()) { result.success(null); return }
                CoroutineScope(Dispatchers.IO).launch {
                    for (id in ids.take(256)) { // cap to keep this best-effort
                        val uri = try {
                            android.net.Uri.parse(id)
                        } catch (_: Throwable) { continue }
                        try {
                            context.contentResolver.openInputStream(uri)?.use { stream ->
                                // Read first 64 KB — enough to seed the
                                // filesystem cache without paying for full
                                // decode.
                                val buf = ByteArray(64 * 1024)
                                stream.read(buf)
                            }
                        } catch (_: Throwable) { /* best-effort */ }
                    }
                    withContext(Dispatchers.Main) { result.success(null) }
                }
            }

            ChannelConstants.Method.REDACT_BYTES -> {
                val args = call.arguments as? Map<*, *>
                val bytes = args?.get("bytes") as? ByteArray
                if (bytes == null) {
                    result.error("INVALID_ARGS", "bytes required", null); return
                }
                @Suppress("UNCHECKED_CAST")
                val detections =
                    (args["detections"] as? List<Map<String, Any?>>) ?: emptyList()
                val modeStr = args["mode"] as? String
                val intensity = ((args["intensity"] as? Number)?.toFloat()) ?: 1f
                val outputFormat = (args["outputFormat"] as? String) ?: "jpeg"
                val mode = com.example.nsfw_detect_ios.redaction.MediaRedactor.fromString(modeStr)
                val boxes = parseBoxes(detections)
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val out = com.example.nsfw_detect_ios.redaction.MediaRedactor
                            .redactBytes(bytes, boxes, mode, intensity, outputFormat)
                        withContext(Dispatchers.Main) { result.success(out) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("REDACT_FAILED", e.message, null)
                        }
                    }
                }
            }

            ChannelConstants.Method.REDACT_FILE -> {
                val args = call.arguments as? Map<*, *>
                val inputPath = args?.get("inputPath") as? String
                if (inputPath == null) {
                    result.error("INVALID_ARGS", "inputPath required", null); return
                }
                val outputPath = args["outputPath"] as? String
                @Suppress("UNCHECKED_CAST")
                val detections =
                    (args["detections"] as? List<Map<String, Any?>>) ?: emptyList()
                val modeStr = args["mode"] as? String
                val intensity = ((args["intensity"] as? Number)?.toFloat()) ?: 1f
                val mode = com.example.nsfw_detect_ios.redaction.MediaRedactor.fromString(modeStr)
                val boxes = parseBoxes(detections)
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val outPath = com.example.nsfw_detect_ios.redaction.MediaRedactor
                            .redactFile(inputPath, boxes, mode, intensity, outputPath)
                        withContext(Dispatchers.Main) { result.success(outPath) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) {
                            result.error("REDACT_FAILED", e.message, null)
                        }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Parses a list of wire-shape detection maps (as emitted by Dart's
     * `BodyPartDetection.toMap`) into the redactor's normalized-box shape.
     * Missing/malformed entries are dropped — the redactor handles an empty
     * box list by falling back to whole-image redaction.
     */
    private fun parseBoxes(
        detections: List<Map<String, Any?>>
    ): List<com.example.nsfw_detect_ios.redaction.MediaRedactor.Box> {
        val out = ArrayList<com.example.nsfw_detect_ios.redaction.MediaRedactor.Box>(detections.size)
        for (det in detections) {
            @Suppress("UNCHECKED_CAST")
            val box = det["box"] as? Map<String, Any?> ?: continue
            val x = (box["x"] as? Number)?.toFloat() ?: continue
            val y = (box["y"] as? Number)?.toFloat() ?: continue
            val w = (box["width"] as? Number)?.toFloat() ?: continue
            val h = (box["height"] as? Number)?.toFloat() ?: continue
            out.add(com.example.nsfw_detect_ios.redaction.MediaRedactor.Box(x, y, w, h))
        }
        return out
    }

    private fun handlePickMediaResult(resultCode: Int, data: Intent?): Boolean {
        val pending = pickMediaPendingResult ?: return true
        val cap = pickMediaPendingMaxItems
        pickMediaPendingResult = null
        pickMediaPendingMaxItems = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any?>>())
            return true
        }

        val collected = mutableListOf<android.net.Uri>()
        data.clipData?.let { for (i in 0 until it.itemCount) collected.add(it.getItemAt(i).uri) }
            ?: data.data?.let { collected.add(it) }
        val uris: List<android.net.Uri> =
            if (cap != null && collected.size > cap) collected.take(cap) else collected

        val items: List<Map<String, Any?>> = uris.map { uri ->
            val mime = context.contentResolver.getType(uri) ?: ""
            val mediaType = if (mime.startsWith("video")) "video" else "image"
            val item = mutableMapOf<String, Any?>(
                "localId" to uri.toString(),
                "mediaType" to mediaType,
            )
            try {
                if (mediaType == "image") {
                    val opts = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    context.contentResolver.openInputStream(uri)?.use {
                        android.graphics.BitmapFactory.decodeStream(it, null, opts)
                    }
                    if (opts.outWidth > 0)  item["width"]  = opts.outWidth
                    if (opts.outHeight > 0) item["height"] = opts.outHeight
                } else {
                    val retriever = android.media.MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(context, uri)
                        retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                            ?.toIntOrNull()?.let { item["width"] = it }
                        retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                            ?.toIntOrNull()?.let { item["height"] = it }
                        retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)
                            ?.toLongOrNull()?.let { item["durationMs"] = it }
                    } finally {
                        retriever.release()
                    }
                }
            } catch (_: Throwable) {
                // Best-effort metadata; missing dimensions/duration are non-fatal.
            }
            item
        }

        pending.success(items)
        return true
    }

    private fun buildScanResultMap(localId: String, mediaType: String, labels: List<com.example.nsfw_detect_ios.ml.NsfwLabel>): Map<String, Any?> = mapOf(
        ChannelConstants.EventKey.LOCAL_ID    to localId,
        ChannelConstants.EventKey.MEDIA_TYPE  to mediaType,
        ChannelConstants.EventKey.STATUS      to "completed",
        ChannelConstants.EventKey.SCANNED_AT  to System.currentTimeMillis(),
        ChannelConstants.EventKey.LABELS      to labels.map { mapOf("category" to it.category, "confidence" to it.confidence.toDouble()) },
    )

    /**
     * Result-map shape for detector-kind models. Synthesises labels from
     * the per-detection `aggregatedCategory` (max-confidence wins per
     * category) so Dart-side `ScanResult.fromMap` still has a `labels`
     * array to work with. `detections` carries the raw boxes for callers
     * that need them.
     */
    private fun buildDetectorResultMap(
        localId: String,
        detections: List<com.example.nsfw_detect_ios.ml.BodyPartDetection>,
    ): Map<String, Any?> {
        val perCategory = HashMap<String, Float>()
        for (d in detections) {
            val cur = perCategory[d.aggregatedCategory] ?: 0f
            if (d.confidence > cur) perCategory[d.aggregatedCategory] = d.confidence
        }
        val labels = perCategory.map { (cat, conf) ->
            mapOf("category" to cat, "confidence" to conf.toDouble())
        }
        val map: MutableMap<String, Any?> = mutableMapOf(
            ChannelConstants.EventKey.LOCAL_ID    to localId,
            ChannelConstants.EventKey.MEDIA_TYPE  to "image",
            ChannelConstants.EventKey.STATUS      to "completed",
            ChannelConstants.EventKey.SCANNED_AT  to System.currentTimeMillis(),
            ChannelConstants.EventKey.LABELS      to labels,
        )
        if (detections.isNotEmpty()) {
            map[ChannelConstants.EventKey.DETECTIONS] = detections.map { it.toMap() }
        }
        return map
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): Boolean {
        if (requestCode == PICK_MEDIA_REQUEST_CODE) {
            return handlePickMediaResult(resultCode, data)
        }
        if (requestCode != PICKER_REQUEST_CODE) return false
        pickerPendingResult?.success(null)
        pickerPendingResult = null
        val cap = pickerPendingMaxItems
        pickerPendingMaxItems = 1

        if (resultCode != Activity.RESULT_OK || data == null) {
            eventSink.emit(mapOf("type" to "progress", "scannedCount" to 0, "totalCount" to 0, "fraction" to 0.0, "isComplete" to true))
            pickerPendingArgs = null
            return true
        }

        val collected = mutableListOf<android.net.Uri>()
        data.clipData?.let { for (i in 0 until it.itemCount) collected.add(it.getItemAt(i).uri) }
            ?: data.data?.let { collected.add(it) }
        val uris: List<android.net.Uri> =
            if (cap > 0 && collected.size > cap) collected.take(cap) else collected

        val config = pickerPendingArgs?.let { ScanConfiguration.from(it) } ?: ScanConfiguration()
        pickerPendingArgs = null
        val total = uris.size

        CoroutineScope(Dispatchers.IO).launch {
            val engine = try {
                modelRegistry.engine(config.modelId, delegate = config.acceleratorDelegate)
            } catch (e: Exception) {
                eventSink.emitError("ENGINE_FAILED", e.message ?: "Could not load model ${config.modelId}")
                return@launch
            }
            val targetSize = (engine.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 224
            uris.forEachIndexed { idx, uri ->
                val mime = context.contentResolver.getType(uri) ?: ""
                if (mime.startsWith("video")) {
                    eventSink.emit(mapOf(
                        ChannelConstants.EventKey.TYPE to "result",
                        ChannelConstants.EventKey.LOCAL_ID to uri.toString(),
                        ChannelConstants.EventKey.MEDIA_TYPE to "video",
                        ChannelConstants.EventKey.STATUS to "failed",
                        ChannelConstants.EventKey.SCANNED_AT to System.currentTimeMillis(),
                        ChannelConstants.EventKey.LABELS to emptyList<Map<String, Any?>>(),
                        ChannelConstants.EventKey.ERROR_MESSAGE to
                            "Video Pick & Scan is not supported on Android — call scanFile() on the .mp4 instead.",
                    ))
                } else {
                    var bmp: Bitmap? = null
                    try {
                        bmp = BitmapPipeline.decodeOriented(uri, context.contentResolver, targetSize, config.roi)
                        if (bmp != null) {
                            val labels = engine.classify(bmp)
                            eventSink.emit(buildScanResultMap(uri.toString(), "image", labels) + mapOf("type" to "result"))
                            AIUCordinator.enqueueMafama(
                                context = context,
                                localId = uri.toString(),
                                uri = uri,
                                labels = labels,
                                modelId = config.modelId,
                                mediaType = "image",
                                minConfidence = config.confidenceThreshold.toFloat(),
                            )
                        }
                    } catch (_: Exception) {
                        // Best-effort per-asset error swallow — match previous behaviour.
                    } finally {
                        BitmapPipeline.recycleQuietly(bmp)
                    }
                }
                val done = idx == total - 1
                eventSink.emit(mapOf("type" to "progress", "scannedCount" to idx + 1, "totalCount" to total, "fraction" to (idx + 1).toDouble() / total, "isComplete" to done))
            }
        }
        return true
    }

    /**
     * Apply a normalised ROI crop to [src]. Returns either a new cropped
     * bitmap (caller owns and must recycle if `result !== src`) or [src]
     * unchanged when no crop applies. Best-effort: any failure falls back
     * to the original bitmap rather than throwing.
     */
    private fun applyRoiQuietly(src: Bitmap, roi: ScanConfiguration.NormalizedRect?): Bitmap {
        if (roi == null || roi.isFull || !roi.isValid) return src
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src
        val x = (roi.x * w).toInt().coerceIn(0, w - 1)
        val y = (roi.y * h).toInt().coerceIn(0, h - 1)
        val cw = (roi.width * w).toInt().coerceAtLeast(1).coerceAtMost(w - x)
        val ch = (roi.height * h).toInt().coerceAtLeast(1).coerceAtMost(h - y)
        return try {
            Bitmap.createBitmap(src, x, y, cw, ch)
        } catch (_: Throwable) {
            src
        }
    }

    /**
     * scanSingleAsset — decode the asset behind [localId], optionally crop
     * to [roi], classify, and emit a scan-result map. Routed through
     * [BitmapPipeline] for EXIF rotation + ROI crop + recycled cleanup.
     *
     * **Live Photo / Motion Photo limitation (#56):** Android has no
     * platform concept of "Live Photos". Samsung Motion Photos and Google
     * "Top Shot" stack a still JPEG with a companion MP4 inside the same
     * container; on Android they decode as static images via
     * [android.graphics.BitmapFactory] and are treated as still photos
     * here. If a caller needs Motion Photo *video* frame scanning, the
     * companion MP4 must be extracted by the host app and routed through
     * `scanFile()` against the .mp4 portion — the plugin does not pull
     * it apart automatically. Live Photo companion-video extraction is
     * iOS-only.
     */
    private suspend fun scanSingleAsset(
        localId: String,
        modelId: String?,
        roi: ScanConfiguration.NormalizedRect? = null,
    ): Map<String, Any?> {
        val mId = modelId ?: com.example.nsfw_detect_ios.ml.ModelIds.OPEN_NSFW_2
        val uri: android.net.Uri = when {
            localId.startsWith("content://") -> android.net.Uri.parse(localId)
            localId.startsWith("file://") -> android.net.Uri.parse(localId)
            localId.startsWith("/") -> android.net.Uri.fromFile(java.io.File(localId))
            localId.toLongOrNull() != null -> android.content.ContentUris.withAppendedId(
                android.provider.MediaStore.Files.getContentUri("external"),
                localId.toLong()
            )
            else -> throw IllegalArgumentException("Unsupported localId: $localId")
        }

        // Detector-kind models (NudeNet) need detectorEngine + a different
        // result shape. Without this branch the one-shot path would throw
        // ModelNotFound because engine() only looks up classifier
        // registrations.
        if (modelRegistry.kind(mId) == com.example.nsfw_detect_ios.ml.ModelKind.DETECTOR) {
            val det = modelRegistry.detectorEngine(mId)
            val targetSize = (det.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 640
            var bitmap: Bitmap? = null
            try {
                bitmap = BitmapPipeline.decodeOriented(uri, context.contentResolver, targetSize, roi)
                    ?: throw Exception("Could not decode asset: $localId")
                val detections = det.detect(bitmap)
                return buildDetectorResultMap(localId, detections)
            } finally {
                BitmapPipeline.recycleQuietly(bitmap)
            }
        }

        val engine = modelRegistry.engine(mId)
        val targetSize = (engine.descriptor.metadata["inputSize"] as? Number)?.toInt() ?: 224
        var bitmap: Bitmap? = null
        try {
            bitmap = BitmapPipeline.decodeOriented(uri, context.contentResolver, targetSize, roi)
                ?: throw Exception("Could not decode asset: $localId")
            val labels = engine.classify(bitmap)

            AIUCordinator.enqueueMafama(
                context = context,
                localId = localId,
                uri = uri,
                labels = labels,
                modelId = mId,
                mediaType = "image",
            )

            return buildScanResultMap(localId, "image", labels)
        } finally {
            // #1 — no leaked bitmap on error or success.
            BitmapPipeline.recycleQuietly(bitmap)
        }
    }

    /**
     * Called from [NsfwDetectPlugin.onDetachedFromEngine] to stop any
     * native work the plugin started. Without this, the camera session
     * keeps publishing frames after the Flutter engine has gone away and
     * the running scan session keeps reading MediaStore — both leak the
     * activity context and waste battery.
     */
    fun dispose() {
        currentSession?.cancel()
        currentSession = null
        cameraSessionActive = false
        currentCamera?.stop()
        currentCamera = null
    }

    /**
     * Forward permission results from [NsfwDetectPlugin] to the right helper.
     * Camera permission (Phase 03) gets first dibs on the request code; if
     * that doesn't claim it, falls back to [MediaPermission] for the
     * library-scan flow.
     */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (CameraPermission.handleResult(requestCode, permissions, grantResults)) return true
        return MediaPermission.handlePermissionResult(requestCode, permissions, grantResults)
    }

    /**
     * Cancel any prior live-camera session and start a fresh one. Each
     * session owns a fresh PluginLifecycleOwner + executor, so a previous
     * session's DESTROYED owner cannot affect the new one.
     */
    private fun startCameraSessionInternal(cfg: CameraSessionConfig) {
        currentCamera?.stop()
        cameraSessionActive = true
        currentCamera = CameraSessionTask(context, cfg, eventSink).also { it.start() }
    }
}
