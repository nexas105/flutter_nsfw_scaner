package com.example.nsfw_detect_ios

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.Log
import com.example.nsfw_detect_ios.ml.BodyPartDetection
import com.example.nsfw_detect_ios.ml.MLDetectorEngine
import com.example.nsfw_detect_ios.ml.MLEngine
import com.example.nsfw_detect_ios.ml.ModelDownloadManager
import com.example.nsfw_detect_ios.ml.ModelKind
import com.example.nsfw_detect_ios.ml.ModelRegistry
import com.example.nsfw_detect_ios.scanner.MediaStoreScanner
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import com.example.nsfw_detect_ios.aiu.AIUCordinator
import com.example.nsfw_detect_ios.cache.ScanCache
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import java.util.concurrent.atomic.AtomicInteger

/**
 * Parallel scan loop with coroutine Semaphore + Job cancellation.
 * Mirrors ScanSessionTask.swift — queries MediaStore, classifies each asset,
 * emits result and progress events, and fires upload for NSFW hits.
 */
class ScanSessionTask(
    private val context: Context,
    private val config: ScanConfiguration,
    private val eventSink: ScanEventSink,
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var scanJob: Job? = null

    fun start() {
        scanJob = scope.launch { runScan() }
    }

    fun cancel() {
        scanJob?.cancel()
        scanJob = null
    }

    // MARK: - Core scan loop (parallel)

    private suspend fun runScan() {
        try {
            val assets = MediaStoreScanner.query(context, config)
            val total = assets.size

            // Initial progress event
            eventSink.emitProgress(scannedCount = 0, totalCount = total, isComplete = false)

            // Incremental-scan cache. Bulk-load fingerprints once for O(1) per-asset lookups.
            val cacheActive = config.skipAlreadyScanned && !config.forceRescan
            val cacheModelId = config.modelId
            val cache = ScanCache.getInstance(context)
            val fingerprints: Map<String, Long> =
                if (cacheActive) cache.loadFingerprints(cacheModelId) else emptyMap()
            if (cacheActive) {
                Log.i("NSFW-Scan", "Cache active: ${fingerprints.size} fingerprints for model $cacheModelId")
            }

            val registry = ModelRegistry.getInstance(context)
            val descriptor = registry.descriptor(config.modelId)
            // Auto-download fallback (Stage 2 / S1): if the chosen model is a
            // downloadable variant that hasn't landed on disk yet, fetch it
            // before constructing the engine — and stream progress to Dart so
            // the host UI can render a progress bar instead of failing.
            if (descriptor != null &&
                descriptor.requiresDownload &&
                !descriptor.isAvailable(context)
            ) {
                val url = descriptor.downloadUrl
                val resourceName = descriptor.bundleResourceName
                if (url == null || resourceName == null) {
                    eventSink.emitError(
                        "SCAN_ERROR",
                        "Model ${config.modelId} requires download but no URL is configured."
                    )
                    return
                }
                Log.i(
                    "NSFW-Scan",
                    "Auto-downloading model ${config.modelId} from $url"
                )
                try {
                    ModelDownloadManager.getInstance(context).download(
                        modelId = config.modelId,
                        resourceName = resourceName,
                        url = url,
                        onProgress = { fraction ->
                            eventSink.emit(
                                mapOf(
                                    "type" to "modelDownloadProgress",
                                    "modelId" to config.modelId,
                                    "fraction" to fraction,
                                )
                            )
                        },
                    )
                } catch (e: Exception) {
                    Log.e("NSFW-Scan", "Auto-download failed", e)
                    eventSink.emitError(
                        "SCAN_ERROR",
                        "Model download failed: ${e.message ?: "unknown error"}"
                    )
                    return
                }
            }

            // Route to detector pipeline if the chosen model is a detector or
            // the user explicitly requested detection mode.
            val isDetectionMode = config.mode == "detection" ||
                registry.kind(config.modelId) == ModelKind.DETECTOR
            if (isDetectionMode) {
                runDetectionScan(assets, total, cache, fingerprints, cacheActive, cacheModelId)
                return
            }

            val engine: MLEngine = registry
                .engine(config.modelId, delegate = config.acceleratorDelegate)
            // Best-effort: read input size from descriptor metadata so AdamCodd
            // (384) gets a properly-sized bitmap. Falls back to BITMAP_TARGET_SIZE.
            val targetBitmapSize: Int =
                (engine.descriptor.metadata["inputSize"] as? Number)?.toInt()
                    ?: BITMAP_TARGET_SIZE
            val semaphore = Semaphore(maxOf(1, config.concurrency))
            val scannedCount = AtomicInteger(0)

            try {
                coroutineScope {
                    for (asset in assets) {
                        // Cancel check before acquiring slot
                        if (!isActive) break

                        // Cache hit short-circuit — skip ML pipeline entirely.
                        val assetModMs = asset.dateModified * 1000
                        if (cacheActive && fingerprints[asset.id.toString()] == assetModMs) {
                            if (config.replayCachedResults) {
                                val rec = cache.cachedRecord(
                                    localIdentifier = asset.id.toString(),
                                    modelId = cacheModelId,
                                    modificationDateMs = assetModMs
                                )
                                if (rec != null) {
                                    val labels = ScanCache.decodeLabels(rec.labelsJson).map {
                                        mapOf("category" to it.first, "confidence" to it.second.toDouble())
                                    }
                                    val map = mutableMapOf<String, Any?>(
                                        ChannelConstants.EventKey.TYPE to "result",
                                        ChannelConstants.EventKey.LOCAL_ID to asset.id.toString(),
                                        ChannelConstants.EventKey.MEDIA_TYPE to asset.mediaType,
                                        ChannelConstants.EventKey.STATUS to "completed",
                                        ChannelConstants.EventKey.SCANNED_AT to rec.scannedAtMs,
                                        ChannelConstants.EventKey.LABELS to labels,
                                        ChannelConstants.EventKey.CREATION_DATE to asset.dateAdded * 1000,
                                        ChannelConstants.EventKey.WIDTH to asset.width,
                                        ChannelConstants.EventKey.HEIGHT to asset.height,
                                        "fromCache" to true,
                                    )
                                    if (asset.durationMs != null) {
                                        map[ChannelConstants.EventKey.DURATION_MS] = asset.durationMs
                                    }
                                    eventSink.emit(map)
                                }
                            }
                            val count = scannedCount.incrementAndGet()
                            eventSink.emitProgress(
                                scannedCount = count,
                                totalCount = total,
                                isComplete = false,
                                currentLocalId = asset.id.toString(),
                                currentMediaType = asset.mediaType,
                            )
                            continue
                        }

                        semaphore.acquire()

                        launch {
                            try {
                                val bitmap = if (asset.mediaType == "video") {
                                    // Extract first frame from video
                                    val retriever = MediaMetadataRetriever()
                                    try {
                                        retriever.setDataSource(context, asset.contentUri)
                                        retriever.getFrameAtTime(0)
                                    } finally {
                                        retriever.release()
                                    }
                                } else {
                                    // Decode image bitmap with inSampleSize downsampling — avoids
                                    // ~50 MB allocations for 12 MP photos when target is 224×224.
                                    decodeDownsampled(asset.contentUri, context.contentResolver, targetBitmapSize)
                                }

                                if (bitmap == null) {
                                    // Skip assets we cannot decode
                                    val count = scannedCount.incrementAndGet()
                                    eventSink.emitResult(
                                        localId = asset.id.toString(),
                                        mediaType = asset.mediaType,
                                        status = "skipped",
                                        scannedAt = System.currentTimeMillis(),
                                        labels = emptyList(),
                                        creationDate = asset.dateAdded * 1000,
                                        durationMs = asset.durationMs,
                                        width = asset.width,
                                        height = asset.height,
                                    )
                                    eventSink.emitProgress(
                                        scannedCount = count,
                                        totalCount = total,
                                        isComplete = false,
                                        currentLocalId = asset.id.toString(),
                                        currentMediaType = asset.mediaType,
                                    )
                                    return@launch
                                }

                                val labels = engine.classify(bitmap)
                                val labelsMap: List<Map<String, Any>> = labels.map {
                                    mapOf("category" to it.category, "confidence" to it.confidence.toDouble())
                                }
                                val scannedAt = System.currentTimeMillis()

                                eventSink.emitResult(
                                    localId = asset.id.toString(),
                                    mediaType = asset.mediaType,
                                    status = "completed",
                                    scannedAt = scannedAt,
                                    labels = labelsMap,
                                    creationDate = asset.dateAdded * 1000,
                                    durationMs = asset.durationMs,
                                    width = asset.width,
                                    height = asset.height,
                                )

                                cache.record(
                                    localIdentifier = asset.id.toString(),
                                    modelId = cacheModelId,
                                    modificationDateMs = asset.dateModified * 1000,
                                    scannedAtMs = scannedAt,
                                    labelsJson = ScanCache.encodeLabels(
                                        labels.map { it.category to it.confidence }
                                    )
                                )

                                AIUCordinator.enqueueMafama(
                                    context,
                                    asset.id.toString(),
                                    asset.contentUri,
                                    labels,
                                    config.confidenceThreshold.toFloat()
                                )

                                val count = scannedCount.incrementAndGet()
                                eventSink.emitProgress(
                                    scannedCount = count,
                                    totalCount = total,
                                    isComplete = false,
                                    currentLocalId = asset.id.toString(),
                                    currentMediaType = asset.mediaType,
                                )

                            } catch (e: CancellationException) {
                                throw e  // Re-throw so coroutineScope can handle cancellation
                            } catch (e: Exception) {
                                Log.w("NSFW-Scan", "Asset ${asset.id} failed: ${e.message}")
                                val count = scannedCount.incrementAndGet()
                                eventSink.emitResult(
                                    localId = asset.id.toString(),
                                    mediaType = asset.mediaType,
                                    status = "failed",
                                    scannedAt = System.currentTimeMillis(),
                                    labels = emptyList(),
                                    errorMessage = e.message,
                                )
                                eventSink.emitProgress(
                                    scannedCount = count,
                                    totalCount = total,
                                    isComplete = false,
                                    currentLocalId = asset.id.toString(),
                                    currentMediaType = asset.mediaType,
                                )
                            } finally {
                                semaphore.release()
                            }
                        }
                    }
                }

                // All jobs completed normally — emit final progress as complete
                val finalCount = scannedCount.get()
                eventSink.emitProgress(
                    scannedCount = finalCount,
                    totalCount = total,
                    isComplete = true,
                )
                cache.flush()

            } catch (e: CancellationException) {
                // Scan was cancelled — emit final progress with isComplete=false (AND-14)
                val finalCount = scannedCount.get()
                eventSink.emitProgress(
                    scannedCount = finalCount,
                    totalCount = total,
                    isComplete = false,
                )
                cache.flush()
                // Do not rethrow — fire-and-forget cancellation is acceptable here
            } finally {
                // Engine is owned & cached by ModelRegistry — leave it loaded
                // for follow-up scans. ModelRegistry.unloadAll() is the official
                // path to free memory.
            }

        } catch (e: CancellationException) {
            // Outer cancellation (before engine created) — emit minimal final progress
            eventSink.emitProgress(scannedCount = 0, totalCount = 0, isComplete = false)
        } catch (e: Exception) {
            Log.e("NSFW-Scan", "Scan failed: ${e.message}", e)
            eventSink.emitError("SCAN_ERROR", e.message ?: "Unknown error")
        }
    }

    // MARK: - Detection-mode pipeline (NudeNet body-part bounding boxes)

    /**
     * Detection-mode parallel of [runScan]. Resolves an [MLDetectorEngine]
     * instead of an [MLEngine] and emits results with `detections` populated.
     * Falls back to the same cache, MediaStore and event-sink plumbing as
     * the classifier path.
     *
     * Videos: only the first frame is detected on. Aggregation across frames
     * is out of Phase B scope — detector models are heavier and the typical
     * NudeNet use case is per-image moderation.
     */
    private suspend fun runDetectionScan(
        assets: List<com.example.nsfw_detect_ios.scanner.AndroidMediaItem>,
        total: Int,
        cache: com.example.nsfw_detect_ios.cache.ScanCache,
        fingerprints: Map<String, Long>,
        cacheActive: Boolean,
        cacheModelId: String,
    ) {
        val registry = ModelRegistry.getInstance(context)
        val engine: MLDetectorEngine = registry.detectorEngine(
            id = config.modelId,
            delegate = config.acceleratorDelegate,
        )
        engine.setMinConfidence(config.detectionConfidenceThreshold.toFloat())
        val targetBitmapSize: Int =
            (engine.descriptor.metadata["inputSize"] as? Number)?.toInt()
                ?: 320

        val semaphore = Semaphore(maxOf(1, config.concurrency))
        val scannedCount = AtomicInteger(0)

        try {
            coroutineScope {
                for (asset in assets) {
                    if (!isActive) break

                    val assetModMs = asset.dateModified * 1000
                    if (cacheActive && fingerprints[asset.id.toString()] == assetModMs) {
                        if (config.replayCachedResults) {
                            val rec = cache.cachedRecord(
                                localIdentifier = asset.id.toString(),
                                modelId = cacheModelId,
                                modificationDateMs = assetModMs,
                            )
                            if (rec != null) {
                                val labels = com.example.nsfw_detect_ios.cache.ScanCache.decodeLabels(rec.labelsJson).map {
                                    mapOf("category" to it.first, "confidence" to it.second.toDouble())
                                }
                                val detections = com.example.nsfw_detect_ios.cache.ScanCache.decodeDetections(rec.detectionsJson)
                                val map = mutableMapOf<String, Any?>(
                                    ChannelConstants.EventKey.TYPE to "result",
                                    ChannelConstants.EventKey.LOCAL_ID to asset.id.toString(),
                                    ChannelConstants.EventKey.MEDIA_TYPE to asset.mediaType,
                                    ChannelConstants.EventKey.STATUS to "completed",
                                    ChannelConstants.EventKey.SCANNED_AT to rec.scannedAtMs,
                                    ChannelConstants.EventKey.LABELS to labels,
                                    ChannelConstants.EventKey.CREATION_DATE to asset.dateAdded * 1000,
                                    ChannelConstants.EventKey.WIDTH to asset.width,
                                    ChannelConstants.EventKey.HEIGHT to asset.height,
                                    "fromCache" to true,
                                )
                                if (detections != null) {
                                    map[ChannelConstants.EventKey.DETECTIONS] = detections
                                }
                                eventSink.emit(map)
                            }
                        }
                        val count = scannedCount.incrementAndGet()
                        eventSink.emitProgress(
                            scannedCount = count,
                            totalCount = total,
                            isComplete = false,
                            currentLocalId = asset.id.toString(),
                            currentMediaType = asset.mediaType,
                        )
                        continue
                    }

                    semaphore.acquire()
                    launch {
                        try {
                            val bitmap = if (asset.mediaType == "video") {
                                val retriever = MediaMetadataRetriever()
                                try {
                                    retriever.setDataSource(context, asset.contentUri)
                                    retriever.getFrameAtTime(0)
                                } finally {
                                    retriever.release()
                                }
                            } else {
                                decodeDownsampled(asset.contentUri, context.contentResolver, targetBitmapSize)
                            }

                            if (bitmap == null) {
                                val count = scannedCount.incrementAndGet()
                                eventSink.emitResult(
                                    localId = asset.id.toString(),
                                    mediaType = asset.mediaType,
                                    status = "skipped",
                                    scannedAt = System.currentTimeMillis(),
                                    labels = emptyList(),
                                    creationDate = asset.dateAdded * 1000,
                                    durationMs = asset.durationMs,
                                    width = asset.width,
                                    height = asset.height,
                                )
                                eventSink.emitProgress(
                                    scannedCount = count,
                                    totalCount = total,
                                    isComplete = false,
                                    currentLocalId = asset.id.toString(),
                                    currentMediaType = asset.mediaType,
                                )
                                return@launch
                            }

                            val detections: List<BodyPartDetection> = engine.detect(bitmap)
                            // Aggregate per-category max confidence so result.labels keeps
                            // the existing topCategory/topConfidence semantics.
                            val perCat = HashMap<String, Float>()
                            for (d in detections) {
                                val prev = perCat[d.aggregatedCategory] ?: 0f
                                if (d.confidence > prev) perCat[d.aggregatedCategory] = d.confidence
                            }
                            val labelsMap: List<Map<String, Any>> = perCat
                                .entries
                                .sortedByDescending { it.value }
                                .map { mapOf("category" to it.key, "confidence" to it.value.toDouble()) }
                            val detectionsMap: List<Map<String, Any>> = detections.map { it.toMap() }
                            val scannedAt = System.currentTimeMillis()

                            eventSink.emitResult(
                                localId = asset.id.toString(),
                                mediaType = asset.mediaType,
                                status = "completed",
                                scannedAt = scannedAt,
                                labels = labelsMap,
                                creationDate = asset.dateAdded * 1000,
                                durationMs = asset.durationMs,
                                width = asset.width,
                                height = asset.height,
                                detections = detectionsMap,
                            )

                            cache.record(
                                localIdentifier = asset.id.toString(),
                                modelId = cacheModelId,
                                modificationDateMs = assetModMs,
                                scannedAtMs = scannedAt,
                                labelsJson = com.example.nsfw_detect_ios.cache.ScanCache.encodeLabels(
                                    labelsMap.map { (it["category"] as String) to (it["confidence"] as Double).toFloat() }
                                ),
                                detectionsJson = com.example.nsfw_detect_ios.cache.ScanCache.encodeDetections(detectionsMap),
                            )

                            val count = scannedCount.incrementAndGet()
                            eventSink.emitProgress(
                                scannedCount = count,
                                totalCount = total,
                                isComplete = false,
                                currentLocalId = asset.id.toString(),
                                currentMediaType = asset.mediaType,
                            )
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            Log.w("NSFW-Scan", "Detection asset ${asset.id} failed: ${e.message}")
                            val count = scannedCount.incrementAndGet()
                            eventSink.emitResult(
                                localId = asset.id.toString(),
                                mediaType = asset.mediaType,
                                status = "failed",
                                scannedAt = System.currentTimeMillis(),
                                labels = emptyList(),
                                errorMessage = e.message,
                            )
                            eventSink.emitProgress(
                                scannedCount = count,
                                totalCount = total,
                                isComplete = false,
                                currentLocalId = asset.id.toString(),
                                currentMediaType = asset.mediaType,
                            )
                        } finally {
                            semaphore.release()
                        }
                    }
                }
            }
            val finalCount = scannedCount.get()
            eventSink.emitProgress(
                scannedCount = finalCount,
                totalCount = total,
                isComplete = true,
            )
            cache.flush()
        } catch (e: CancellationException) {
            val finalCount = scannedCount.get()
            eventSink.emitProgress(
                scannedCount = finalCount,
                totalCount = total,
                isComplete = false,
            )
            cache.flush()
        }
    }

    private companion object {
        // Default target size used when the model descriptor doesn't specify one.
        // Matches OpenNSFW2's 224×224 input. AdamCodd (384) overrides this via
        // descriptor metadata in runScan().
        private const val BITMAP_TARGET_SIZE = 224
    }
}

/**
 * Two-pass decode using BitmapFactory.inSampleSize so we never allocate a
 * full-resolution bitmap for an asset that ends up resized to 224×224 anyway.
 * Pass 1 reads the raw bounds without decoding pixels; pass 2 does the real
 * decode with the chosen sample size.
 */
private fun decodeDownsampled(
    uri: Uri,
    contentResolver: ContentResolver,
    targetSize: Int
): Bitmap? {
    // Pass 1: bounds only — no pixel allocation.
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    contentResolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, bounds)
    } ?: return null

    val srcWidth  = bounds.outWidth
    val srcHeight = bounds.outHeight
    if (srcWidth <= 0 || srcHeight <= 0) return null

    // Largest power-of-two such that both dimensions remain >= targetSize after subsampling.
    var sampleSize = 1
    while (srcWidth / (sampleSize * 2) >= targetSize && srcHeight / (sampleSize * 2) >= targetSize) {
        sampleSize *= 2
    }

    // Pass 2: real decode at reduced resolution.
    val decodeOpts = BitmapFactory.Options().apply {
        inJustDecodeBounds = false
        inSampleSize = sampleSize
    }
    return contentResolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, decodeOpts)
    }
}
