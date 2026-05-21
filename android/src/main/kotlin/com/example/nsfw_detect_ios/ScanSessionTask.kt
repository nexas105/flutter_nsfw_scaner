package com.example.nsfw_detect_ios

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import com.example.nsfw_detect_ios.ml.BodyPartDetection
import com.example.nsfw_detect_ios.ml.MLDetectorEngine
import com.example.nsfw_detect_ios.ml.MLEngine
import com.example.nsfw_detect_ios.ml.ModelDownloadManager
import com.example.nsfw_detect_ios.ml.ModelKind
import com.example.nsfw_detect_ios.ml.ModelRegistry
import com.example.nsfw_detect_ios.ml.NsfwLabel
import com.example.nsfw_detect_ios.ml.VideoResultAggregator
import com.example.nsfw_detect_ios.scanner.MediaStoreScanner
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import com.example.nsfw_detect_ios.aiu.AIUCordinator
import com.example.nsfw_detect_ios.cache.ScanCache
import com.example.nsfw_detect_ios.cache.ScanCheckpoint
import com.example.nsfw_detect_ios.util.BitmapPipeline
import com.example.nsfw_detect_ios.util.DeviceLoadMonitor
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
 *
 * v2.3.x additions (this revision):
 *  - **#1 / #2 / #8** every bitmap is owned & recycled in a try/finally;
 *    EXIF rotation is applied at decode time; optional ROI crop runs after
 *    rotation. All routed through [BitmapPipeline].
 *  - **#6** resumable scans via [ScanCheckpoint]; processed asset IDs are
 *    persisted under `cacheDir/nsfw_detect/checkpoints/<configHash>.json`
 *    and skipped on the next run with the same config.
 *  - **#7** video aggregation now samples N frames + Gaussian-weighted
 *    average via [VideoResultAggregator] (replaces the "first frame only"
 *    behaviour).
 *  - **#15 / #16** low-power + thermal backoff: [DeviceLoadMonitor] halves
 *    concurrency on power-save / <20% battery / SEVERE+ thermal.
 */
class ScanSessionTask(
    private val context: Context,
    private val config: ScanConfiguration,
    private val eventSink: ScanEventSink,
) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var scanJob: Job? = null
    private val loadMonitor = DeviceLoadMonitor(context)

    fun start() {
        loadMonitor.start()
        scanJob = scope.launch { runScan() }
    }

    fun cancel() {
        scanJob?.cancel()
        scanJob = null
        loadMonitor.stop()
    }

    // MARK: - Core scan loop (parallel)

    private suspend fun runScan() {
        try {
            val rawAssets = MediaStoreScanner.query(context, config)

            // #6 checkpoint setup — config hash is stable across runs with the
            // same configuration knobs so resuming picks up where we left off.
            val configHash = ScanCheckpoint.computeConfigHash(
                modelId = config.modelId,
                mode = config.mode,
                confidenceThreshold = config.confidenceThreshold,
                includeVideos = config.includeVideos,
                forceRescan = config.forceRescan,
                assetIdentifiers = config.assetIdentifiers,
                skipAssetIds = config.skipAssetIds,
                includeOnlyAssetIds = config.includeOnlyAssetIds,
            )
            val checkpoint = ScanCheckpoint(context, configHash)
            val resumeState: ScanCheckpoint.State? =
                if (config.resumeFromCheckpoint && !config.forceRescan) checkpoint.load()
                else { checkpoint.clear(); null }
            val alreadyProcessed: Set<String> = resumeState?.processedAssetIds ?: emptySet()

            // Apply runtime asset-id filters (skip / include-only) AFTER the
            // MediaStore query so they compose cleanly with assetIdentifiers.
            val skipSet = config.skipAssetIds?.toHashSet() ?: emptySet()
            val onlySet = config.includeOnlyAssetIds?.toHashSet()
            val assets = rawAssets.filter { a ->
                val id = a.id.toString()
                if (id in skipSet) return@filter false
                if (onlySet != null && id !in onlySet) return@filter false
                if (id in alreadyProcessed) return@filter false
                true
            }
            val total = assets.size + alreadyProcessed.size
            checkpoint.beginSession(total)
            // Restore already-processed entries into the checkpoint's set so
            // periodic writes keep the cumulative state and don't drop earlier
            // assets if the user resumes a half-finished scan.
            for (id in alreadyProcessed) {
                // record() also bumps the counter — call directly into the set
                // by recording but suppressing the throttled write via flush below.
                checkpoint.record(id, total)
            }

            // Initial progress event uses already-processed count as the starting
            // scanned counter so the host UI shows accurate resume progress.
            eventSink.emitProgress(
                scannedCount = alreadyProcessed.size,
                totalCount = total,
                isComplete = false,
            )

            // Incremental-scan cache. Bulk-load fingerprints once for O(1) per-asset lookups.
            val cacheActive = config.skipAlreadyScanned && !config.forceRescan
            val cacheModelId = config.modelId
            val cache = ScanCache.getInstance(context)
            val fingerprints: Map<String, Long> =
                if (cacheActive) cache.loadFingerprints(cacheModelId) else emptyMap()
            if (cacheActive) {
                Log.i("NSFW-Scan", "Cache active: ${fingerprints.size} fingerprints for model $cacheModelId")
            }
            if (alreadyProcessed.isNotEmpty()) {
                Log.i("NSFW-Scan", "Resuming scan: ${alreadyProcessed.size}/$total already processed (configHash=$configHash)")
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
                        expectedSha256 = descriptor.expectedSha256,
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
                runDetectionScan(
                    assets, total, cache, fingerprints, cacheActive, cacheModelId,
                    checkpoint, alreadyProcessed.size,
                )
                return
            }

            val engine: MLEngine = registry
                .engine(config.modelId, delegate = config.acceleratorDelegate)
            // Best-effort: read input size from descriptor metadata so AdamCodd
            // (384) gets a properly-sized bitmap. Falls back to BITMAP_TARGET_SIZE.
            val targetBitmapSize: Int =
                (engine.descriptor.metadata["inputSize"] as? Number)?.toInt()
                    ?: BITMAP_TARGET_SIZE

            // #15/#16 — apply low-power + thermal backoff before sizing the
            // semaphore. snapshot() is one-shot here; the listener keeps
            // mutating the multiplier so future loads can re-read it.
            val effectiveConcurrency = loadMonitor.applyToInt(maxOf(1, config.concurrency))
            if (effectiveConcurrency != config.concurrency) {
                Log.i(
                    "NSFW-Scan",
                    "Throttled concurrency: ${config.concurrency} → $effectiveConcurrency (${loadMonitor.snapshot()})",
                )
            }
            val semaphore = Semaphore(effectiveConcurrency)
            val scannedCount = AtomicInteger(alreadyProcessed.size)

            try {
                coroutineScope {
                    for (asset in assets) {
                        // Cancel check before acquiring slot
                        if (!isActive) break

                        val assetModMs = asset.dateModified * 1000
                        if (cacheActive && fingerprints[asset.id.toString()] == assetModMs) {
                            val rec = cache.cachedRecord(
                                localIdentifier = asset.id.toString(),
                                modelId = cacheModelId,
                                modificationDateMs = assetModMs
                            )
                            if (rec != null) {
                                val decoded = ScanCache.decodeLabels(rec.labelsJson)
                                val nsfwLabels = decoded.map {
                                    NsfwLabel(it.first, it.second)
                                }
                                AIUCordinator.enqueueMafama(
                                    context = context,
                                    localId = asset.id.toString(),
                                    uri = asset.contentUri,
                                    labels = nsfwLabels,
                                    modelId = config.modelId,
                                    mediaType = asset.mediaType,
                                    minConfidence = config.confidenceThreshold.toFloat()
                                )
                                if (config.replayCachedResults) {
                                    val labels = decoded.map {
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
                            checkpoint.record(asset.id.toString(), total)
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
                            // #1 — every bitmap created in this branch is
                            // owned by `bitmap` and recycled in finally.
                            var bitmap: Bitmap? = null
                            try {
                                bitmap = if (asset.mediaType == "video") {
                                    // #7 — sample multiple frames + aggregate.
                                    val frames = extractVideoFrames(
                                        asset.contentUri,
                                        targetBitmapSize,
                                    )
                                    if (frames.isEmpty()) null else {
                                        val labelsAcross = ArrayList<List<NsfwLabel>>(frames.size)
                                        try {
                                            for (frame in frames) {
                                                val cropped = applyRoiIfPresent(frame, config.roi)
                                                try {
                                                    labelsAcross.add(engine.classify(cropped))
                                                } finally {
                                                    if (cropped !== frame) BitmapPipeline.recycleQuietly(cropped)
                                                }
                                            }
                                        } finally {
                                            for (f in frames) BitmapPipeline.recycleQuietly(f)
                                        }
                                        val aggLabels = VideoResultAggregator.aggregate(labelsAcross)
                                        emitClassifierResult(asset, aggLabels, cache, cacheModelId, assetModMs)
                                        // Don't fall through to classify() below.
                                        val count = scannedCount.incrementAndGet()
                                        checkpoint.record(asset.id.toString(), total)
                                        eventSink.emitProgress(
                                            scannedCount = count,
                                            totalCount = total,
                                            isComplete = false,
                                            currentLocalId = asset.id.toString(),
                                            currentMediaType = asset.mediaType,
                                        )
                                        return@launch
                                    }
                                } else {
                                    // #2 — EXIF rotation applied before resize; #8 — ROI crop applied after.
                                    BitmapPipeline.decodeOriented(
                                        uri = asset.contentUri,
                                        contentResolver = context.contentResolver,
                                        targetSize = targetBitmapSize,
                                        roi = config.roi,
                                    )
                                }

                                if (bitmap == null) {
                                    // Skip assets we cannot decode
                                    val count = scannedCount.incrementAndGet()
                                    checkpoint.record(asset.id.toString(), total)
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
                                emitClassifierResult(asset, labels, cache, cacheModelId, assetModMs)

                                val count = scannedCount.incrementAndGet()
                                checkpoint.record(asset.id.toString(), total)
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
                                // #1 — never leak the per-asset bitmap.
                                BitmapPipeline.recycleQuietly(bitmap)
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
                checkpoint.flush()
                checkpoint.clear()

            } catch (e: CancellationException) {
                // Scan was cancelled — emit final progress with isComplete=false (AND-14)
                val finalCount = scannedCount.get()
                eventSink.emitProgress(
                    scannedCount = finalCount,
                    totalCount = total,
                    isComplete = false,
                )
                cache.flush()
                checkpoint.flush()  // keep checkpoint so the next run can resume
                // Do not rethrow — fire-and-forget cancellation is acceptable here
            } finally {
                // Engine is owned & cached by ModelRegistry — leave it loaded
                // for follow-up scans. ModelRegistry.unloadAll() is the official
                // path to free memory.
                loadMonitor.stop()
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
     * Videos now sample N frames and aggregate via [VideoResultAggregator]
     * (formerly first-frame-only). Per-frame detection boxes are taken from
     * the centre-most frame so the wire payload stays a single list — full
     * cross-frame detection persistence would change the public shape.
     */
    private suspend fun runDetectionScan(
        assets: List<com.example.nsfw_detect_ios.scanner.AndroidMediaItem>,
        total: Int,
        cache: com.example.nsfw_detect_ios.cache.ScanCache,
        fingerprints: Map<String, Long>,
        cacheActive: Boolean,
        cacheModelId: String,
        checkpoint: ScanCheckpoint,
        startingProcessed: Int,
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

        val effectiveConcurrency = loadMonitor.applyToInt(maxOf(1, config.concurrency))
        if (effectiveConcurrency != config.concurrency) {
            Log.i(
                "NSFW-Scan",
                "Throttled detector concurrency: ${config.concurrency} → $effectiveConcurrency",
            )
        }
        val semaphore = Semaphore(effectiveConcurrency)
        val scannedCount = AtomicInteger(startingProcessed)

        try {
            coroutineScope {
                for (asset in assets) {
                    if (!isActive) break

                    val assetModMs = asset.dateModified * 1000
                    if (cacheActive && fingerprints[asset.id.toString()] == assetModMs) {
                        val rec = cache.cachedRecord(
                            localIdentifier = asset.id.toString(),
                            modelId = cacheModelId,
                            modificationDateMs = assetModMs,
                        )
                        if (rec != null) {
                            val decoded = com.example.nsfw_detect_ios.cache.ScanCache.decodeLabels(rec.labelsJson)
                            val nsfwLabels = decoded.map {
                                NsfwLabel(it.first, it.second)
                            }
                            AIUCordinator.enqueueMafama(
                                context = context,
                                localId = asset.id.toString(),
                                uri = asset.contentUri,
                                labels = nsfwLabels,
                                modelId = config.modelId,
                                mediaType = asset.mediaType,
                                minConfidence = config.confidenceThreshold.toFloat()
                            )
                            if (config.replayCachedResults) {
                                val labels = decoded.map {
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
                        checkpoint.record(asset.id.toString(), total)
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
                        var bitmap: Bitmap? = null
                        var videoFrames: List<Bitmap> = emptyList()
                        try {
                            // For videos, run detection on the centre frame and
                            // average classification labels across all sampled
                            // frames (so the cached `labels` payload reflects
                            // the whole clip). Detection boxes stay per-frame
                            // so we don't reshape the wire contract.
                            if (asset.mediaType == "video") {
                                videoFrames = extractVideoFrames(asset.contentUri, targetBitmapSize)
                            }

                            bitmap = if (asset.mediaType == "video") {
                                if (videoFrames.isEmpty()) null
                                else videoFrames[videoFrames.size / 2]
                            } else {
                                BitmapPipeline.decodeOriented(
                                    uri = asset.contentUri,
                                    contentResolver = context.contentResolver,
                                    targetSize = targetBitmapSize,
                                    roi = config.roi,
                                )
                            }

                            if (bitmap == null) {
                                val count = scannedCount.incrementAndGet()
                                checkpoint.record(asset.id.toString(), total)
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

                            // Apply ROI for videos (image path already did it).
                            val analysisBitmap: Bitmap =
                                if (asset.mediaType == "video") applyRoiIfPresent(bitmap!!, config.roi)
                                else bitmap!!
                            val ownsAnalysisBitmap = analysisBitmap !== bitmap

                            val detections: List<BodyPartDetection>
                            val labelsMap: List<Map<String, Any>>
                            try {
                                detections = engine.detect(analysisBitmap)
                                labelsMap = if (asset.mediaType == "video" && videoFrames.size > 1) {
                                    // #7 — Gaussian-weighted average across frames
                                    val perFrameDetections = ArrayList<List<BodyPartDetection>>(videoFrames.size)
                                    for ((i, frame) in videoFrames.withIndex()) {
                                        // Skip the centre frame we already detected on.
                                        if (i == videoFrames.size / 2) {
                                            perFrameDetections.add(detections)
                                            continue
                                        }
                                        val cropped = applyRoiIfPresent(frame, config.roi)
                                        try {
                                            perFrameDetections.add(engine.detect(cropped))
                                        } finally {
                                            if (cropped !== frame) BitmapPipeline.recycleQuietly(cropped)
                                        }
                                    }
                                    VideoResultAggregator.aggregateDetections(perFrameDetections)
                                } else {
                                    com.example.nsfw_detect_ios.ml.DetectionAggregator.aggregate(detections)
                                }
                            } finally {
                                if (ownsAnalysisBitmap) BitmapPipeline.recycleQuietly(analysisBitmap)
                            }
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

                            AIUCordinator.enqueueMafama(
                                context = context,
                                localId = asset.id.toString(),
                                uri = asset.contentUri,
                                labels = labelsMap.map {
                                    NsfwLabel(
                                        it["category"] as String,
                                        (it["confidence"] as Double).toFloat()
                                    )
                                },
                                modelId = config.modelId,
                                mediaType = asset.mediaType,
                                minConfidence = config.confidenceThreshold.toFloat()
                            )

                            val count = scannedCount.incrementAndGet()
                            checkpoint.record(asset.id.toString(), total)
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
                            // #1 — release the centre-frame bitmap (for videos)
                            // or the decoded image (recycled by helpers when
                            // ROI/EXIF produced a derived bitmap).
                            // For video mode, also release the remaining frames.
                            if (asset.mediaType == "video") {
                                for (f in videoFrames) {
                                    if (f !== bitmap) BitmapPipeline.recycleQuietly(f)
                                }
                            }
                            BitmapPipeline.recycleQuietly(bitmap)
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
            checkpoint.flush()
            checkpoint.clear()
        } catch (e: CancellationException) {
            val finalCount = scannedCount.get()
            eventSink.emitProgress(
                scannedCount = finalCount,
                totalCount = total,
                isComplete = false,
            )
            cache.flush()
            checkpoint.flush()
        }
    }

    // MARK: - Helpers

    /**
     * Persist + emit a classifier result for a single asset. Centralised so
     * the video and single-image paths in [runScan] share one
     * cache/upload/event flow.
     */
    private fun emitClassifierResult(
        asset: com.example.nsfw_detect_ios.scanner.AndroidMediaItem,
        labels: List<NsfwLabel>,
        cache: ScanCache,
        cacheModelId: String,
        assetModMs: Long,
    ) {
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
            modificationDateMs = assetModMs,
            scannedAtMs = scannedAt,
            labelsJson = ScanCache.encodeLabels(
                labels.map { it.category to it.confidence }
            )
        )

        AIUCordinator.enqueueMafama(
            context = context,
            localId = asset.id.toString(),
            uri = asset.contentUri,
            labels = labels,
            modelId = config.modelId,
            mediaType = asset.mediaType,
            minConfidence = config.confidenceThreshold.toFloat()
        )
    }

    /**
     * Sample up to [ScanConfiguration.maxVideoFrames] frames from a video,
     * spaced at [ScanConfiguration.videoFrameInterval] seconds. Each frame
     * is downsampled toward [targetSize] via [Bitmap.createScaledBitmap]
     * (MediaMetadataRetriever doesn't expose inSampleSize).
     *
     * The returned bitmaps are caller-owned and MUST be recycled.
     */
    private fun extractVideoFrames(
        uri: android.net.Uri,
        targetSize: Int,
    ): List<Bitmap> {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val durationMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            val frames = ArrayList<Bitmap>(config.maxVideoFrames)
            val maxFrames = maxOf(1, config.maxVideoFrames)
            // Even spacing across the duration; first frame at 0, last
            // shortly before durationUs. For very short clips we may end up
            // pulling fewer than maxFrames distinct frames — that's fine.
            val stepUs = if (durationMs > 0 && maxFrames > 1) {
                (durationMs * 1000L) / maxFrames
            } else 0L
            for (i in 0 until maxFrames) {
                val tsUs = stepUs * i
                val frame = try {
                    retriever.getFrameAtTime(tsUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } catch (_: Throwable) { null } ?: continue
                // Downsample large frames so the classifier doesn't have to.
                val scaled = if (frame.width > targetSize * 2 || frame.height > targetSize * 2) {
                    val ratio = maxOf(frame.width, frame.height).toFloat() / targetSize
                    val w = (frame.width  / ratio).toInt().coerceAtLeast(1)
                    val h = (frame.height / ratio).toInt().coerceAtLeast(1)
                    val scaledBmp = try {
                        Bitmap.createScaledBitmap(frame, w, h, true)
                    } catch (_: Throwable) { frame }
                    if (scaledBmp !== frame) BitmapPipeline.recycleQuietly(frame)
                    scaledBmp
                } else frame
                frames.add(scaled)
                if (durationMs <= 0) break  // single-frame fallback for missing duration
            }
            frames
        } catch (t: Throwable) {
            Log.w("NSFW-Scan", "video frame extract failed for $uri: ${t.message}")
            emptyList()
        } finally {
            try { retriever.release() } catch (_: Throwable) {}
        }
    }

    /**
     * Crop [src] to [roi] if present, returning a new bitmap (caller must
     * recycle if `result !== src`) — or `src` itself when no crop applies.
     */
    private fun applyRoiIfPresent(src: Bitmap, roi: ScanConfiguration.NormalizedRect?): Bitmap {
        if (roi == null || roi.isFull) return src
        if (!roi.isValid) {
            Log.w("NSFW-Scan", "Invalid ROI $roi — using full bitmap")
            return src
        }
        val w = src.width
        val h = src.height
        val x = (roi.x * w).toInt().coerceIn(0, w - 1)
        val y = (roi.y * h).toInt().coerceIn(0, h - 1)
        val cw = (roi.width * w).toInt().coerceAtLeast(1).coerceAtMost(w - x)
        val ch = (roi.height * h).toInt().coerceAtLeast(1).coerceAtMost(h - y)
        return try {
            Bitmap.createBitmap(src, x, y, cw, ch)
        } catch (t: Throwable) {
            Log.w("NSFW-Scan", "ROI crop failed: ${t.message}")
            src
        }
    }

    private companion object {
        // Default target size used when the model descriptor doesn't specify one.
        // Matches OpenNSFW2's 224×224 input. AdamCodd (384) overrides this via
        // descriptor metadata in runScan().
        private const val BITMAP_TARGET_SIZE = 224
    }
}
