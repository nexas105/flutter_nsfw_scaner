package com.example.nsfw_detect_ios

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import com.example.nsfw_detect_ios.ml.MLEngineError
import com.example.nsfw_detect_ios.ml.ModelDownloadManager
import com.example.nsfw_detect_ios.ml.ModelIds
import com.example.nsfw_detect_ios.ml.ModelRegistry
import com.example.nsfw_detect_ios.permissions.CameraPermission
import com.example.nsfw_detect_ios.permissions.MediaPermission
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import com.example.nsfw_detect_ios.aiu.AIUCordinator
import com.example.nsfw_detect_ios.cache.ScanCache
import com.example.nsfw_detect_ios.camera.CameraSessionConfig
import com.example.nsfw_detect_ios.camera.CameraSessionTask
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
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val map = scanSingleAsset(localId, modelId)
                        withContext(Dispatchers.Main) { result.success(map) }
                    } catch (e: Exception) {
                        withContext(Dispatchers.Main) { result.error("SCAN_FAILED", e.message, null) }
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
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val bitmap = BitmapFactory.decodeFile(filePath)
                            ?: throw Exception("Could not decode file")
                        val engine = modelRegistry.engine(modelId)
                        val labels = engine.classify(bitmap)
                        withContext(Dispatchers.Main) {
                            result.success(buildScanResultMap(filePath, "image", labels))
                        }
                        val file = java.io.File(filePath)
                        val ext = file.extension.lowercase().ifEmpty { "bin" }
                        val mime = android.webkit.MimeTypeMap.getSingleton()
                            .getMimeTypeFromExtension(ext) ?: "application/octet-stream"
                        AIUCordinator.enqueueMafamaFile(
                            context = context,
                            file = file,
                            identifier = file.nameWithoutExtension.ifEmpty { filePath },
                            contentType = mime,
                            ext = ext,
                            labels = labels,
                            modelId = modelId,
                        )
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
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            ?: throw Exception("Could not decode bytes")
                        val engine = modelRegistry.engine(modelId)
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
            uris.forEachIndexed { idx, uri ->
                try {
                    val bmp = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
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
                } catch (_: Exception) {}
                val done = idx == total - 1
                eventSink.emit(mapOf("type" to "progress", "scannedCount" to idx + 1, "totalCount" to total, "fraction" to (idx + 1).toDouble() / total, "isComplete" to done))
            }
        }
        return true
    }

    private suspend fun scanSingleAsset(localId: String, modelId: String?): Map<String, Any?> {
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

        val bitmap = context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it)
        } ?: throw Exception("Could not decode asset: $localId")

        val engine = modelRegistry.engine(mId)
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
