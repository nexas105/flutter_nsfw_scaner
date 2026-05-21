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
import com.example.nsfw_detect_ios.ml.VideoResultAggregator
import com.example.nsfw_detect_ios.cache.ScanCache
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

    /** Shared model registry — replaces the legacy single-engine field. */
    private val modelRegistry: ModelRegistry = ModelRegistry.getInstance(context)
    private val downloadManager: ModelDownloadManager = ModelDownloadManager.getInstance(context)

    private val PICKER_REQUEST_CODE = 9847
    private val PICK_MEDIA_REQUEST_CODE = 9848
    private var pickerPendingResult: MethodChannel.Result? = null
    private var pickerPendingArgs: Map<*, *>? = null
    private var pickMediaPendingResult: MethodChannel.Result? = null

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
                currentSession?.cancel()
                // ScanSessionTask created in Plan 04-02 — forward declaration only
                currentSession = ScanSessionTask(context, config, eventSink)
                CoroutineScope(Dispatchers.IO).launch {
                    currentSession?.start()
                }
                result.success(null)
            }

            ChannelConstants.Method.CANCEL_SCAN -> {
                currentSession?.cancel()
                currentSession = null
                result.success(null)
            }

            ChannelConstants.Method.RESET_SCAN -> {
                currentSession?.cancel()
                currentSession = null
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
                pickMediaPendingResult = result
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
                val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()
                val cfg = CameraSessionConfig.from(args)
                val act = activity
                when {
                    CameraPermission.isGranted(context) -> {
                        startCameraSessionInternal(cfg)
                        result.success(null)
                    }
                    act != null -> {
                        CameraPermission.request(act) { granted ->
                            if (granted) {
                                startCameraSessionInternal(cfg)
                            } else {
                                eventSink.emitCameraPermissionDenied()
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
                currentCamera?.stop()
                currentCamera = null
                result.success(null)
            }

            ChannelConstants.Method.PICK_AND_SCAN -> {
                val act = activity
                if (act == null) { result.error("NO_ACTIVITY", "Activity not available", null); return }
                val args = call.arguments as? Map<*, *>
                val maxItems = (args?.get("maxItems") as? Int) ?: 1
                pickerPendingResult = result
                pickerPendingArgs = args
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "image/*"
                    if (maxItems != 1) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                @Suppress("DEPRECATION")
                act.startActivityForResult(intent, PICKER_REQUEST_CODE)
            }

            else -> result.notImplemented()
        }
    }

    private fun handlePickMediaResult(resultCode: Int, data: Intent?): Boolean {
        val pending = pickMediaPendingResult ?: return true
        pickMediaPendingResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any?>>())
            return true
        }

        val uris = mutableListOf<android.net.Uri>()
        data.clipData?.let { for (i in 0 until it.itemCount) uris.add(it.getItemAt(i).uri) }
            ?: data.data?.let { uris.add(it) }

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

    fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): Boolean {
        if (requestCode == PICK_MEDIA_REQUEST_CODE) {
            return handlePickMediaResult(resultCode, data)
        }
        if (requestCode != PICKER_REQUEST_CODE) return false
        pickerPendingResult?.success(null)
        pickerPendingResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            eventSink.emit(mapOf("type" to "progress", "scannedCount" to 0, "totalCount" to 0, "fraction" to 0.0, "isComplete" to true))
            pickerPendingArgs = null
            return true
        }

        val uris = mutableListOf<android.net.Uri>()
        data.clipData?.let { for (i in 0 until it.itemCount) uris.add(it.getItemAt(i).uri) }
            ?: data.data?.let { uris.add(it) }

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
                var bmp: Bitmap? = null
                try {
                    // #1/#2/#8 — EXIF rotation + ROI crop + leak-safe recycle.
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
        currentCamera = CameraSessionTask(context, cfg, eventSink).also { it.start() }
    }
}
