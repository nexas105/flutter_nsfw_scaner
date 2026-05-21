import Foundation
import Photos
import os

/// Represents a running full-library scan. Cancellable.
///
/// Thread-safety: `_effectiveConcurrency` is guarded by `loadLock`; `task`,
/// `loadObserver` are mutated exclusively on the calling actor (the
/// platform-channel thread that builds the session). `@unchecked Sendable`
/// is correct because the lock+single-writer discipline replaces what the
/// type system would otherwise check.
final class ScanSessionTask: @unchecked Sendable {

    private let config: ScanConfiguration
    private let eventSink: ScanEventSink
    private var task: Task<Void, Never>?

    /// Effective concurrency for this scan after DeviceLoadMonitor multipliers
    /// (low-power + thermal) have been applied. Recomputed live whenever the
    /// monitor posts a change. Reads guarded by `loadLock`.
    private let loadLock = OSAllocatedUnfairLock()
    private var _effectiveConcurrency: Int
    private var loadObserver: NSObjectProtocol?

    init(config: ScanConfiguration, eventSink: ScanEventSink) {
        self.config    = config
        self.eventSink = eventSink
        // Seed with the snapshot at construction time — DeviceLoadMonitor is
        // a process-wide singleton, so reading it here is cheap.
        let base = max(1, config.concurrency)
        self._effectiveConcurrency = DeviceLoadMonitor.shared.scaledWorkers(base: base)
    }

    deinit {
        if let observer = loadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() async {
        // Subscribe to load-factor changes so an in-flight scan reacts to
        // low-power toggling on or the thermal envelope dropping. The
        // worker-count check inside the inner loop reads the updated value.
        let base = max(1, config.concurrency)
        loadObserver = NotificationCenter.default.addObserver(
            forName: DeviceLoadMonitor.loadFactorDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            let updated = DeviceLoadMonitor.shared.scaledWorkers(base: base)
            let previous: Int = self.loadLock.withLock {
                let p = self._effectiveConcurrency
                self._effectiveConcurrency = updated
                return p
            }
            if previous != updated {
                NSLog("[NSFW] DeviceLoadMonitor: concurrency %d → %d (factor=%.2f)",
                      previous, updated,
                      DeviceLoadMonitor.shared.currentLoadFactor)
            }
        }

        task = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.runScan()
        }
        await task?.value
    }

    /// Signal cancellation. Returns immediately; the underlying Task observes
    /// the cancellation at the next `await` checkpoint. See `cancelAndWait()`
    /// for callers that need to know the teardown is fully done before
    /// touching shared state (checkpoint key, eventSink ordering, etc).
    func cancel() {
        task?.cancel()
    }

    /// Cancel and await the Task's full teardown. Use this before starting a
    /// fresh session on the same channel — otherwise a still-running old
    /// runScan can emit progress events / overwrite the checkpoint key
    /// after the new session has already begun (C1).
    func cancelAndWait() async {
        task?.cancel()
        _ = await task?.value
    }

    /// Live, throttle-aware concurrency. Always ≥ 1.
    private var effectiveConcurrency: Int {
        loadLock.withLock { max(1, _effectiveConcurrency) }
    }

    // MARK: - Core scan loop

    private func runScan() async {
        do {
            NSLog("[NSFW] Starting scan with model: %@", config.modelId)

            // Branch on detector kind. Detection-mode runs through a parallel
            // pipeline that emits NudeNet-style bounding boxes; classification
            // mode keeps the existing batch-classifier path untouched.
            let kind = ModelRegistry.shared.kind(for: config.modelId)
            let isDetectionMode = (config.mode == "detection") || (kind == .detector)
            if isDetectionMode {
                try await runDetectionScan()
                return
            }

            let engine     = try await ModelRegistry.shared.engine(for: config.modelId, computeUnits: config.computeUnits)
            engine.configure(
                detectionConfidence: Float(config.detectionConfidenceThreshold),
                iou: Float(config.iouThreshold)
            )
            NSLog("[NSFW] Model loaded successfully")
            let inputSize  = engine.descriptor.metadata["inputSize"] as? Int ?? 224
            // VideoFrameSampler now applies the ROI crop + perceptual dedupe
            // before frames hit the inference pipeline (see Tasks #17 / #21).
            let sampler    = VideoFrameSampler(
                enablePerceptualDedupe: true,
                region: config.roi
            )
            let aggregator = VideoResultAggregator()

            // Prefetch manager — starts loading image data before we need it.
            // Routed through ImageAnalyzer so requestImage hits the prefetched cache
            // (must use identical targetSize/contentMode/options).
            let cachingManager = PHCachingImageManager()
            cachingManager.allowsCachingHighQualityImages = false
            let analyzer   = ImageAnalyzer(inputSize: inputSize, imageManager: cachingManager)

            // Build fetch options
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if !config.includeVideos {
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d",
                    PHAssetMediaType.image.rawValue
                )
            }

            let fetchResult: PHFetchResult<PHAsset>
            // Honour Dart-side include/skip filters. `includeOnlyAssetIds`
            // wins when both are present (skip is then a no-op because the
            // fetch is already restricted to that allow-list). `assetIdentifiers`
            // (legacy pick-and-scan list) takes priority over both.
            if let ids = config.assetIdentifiers {
                fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: fetchOptions)
            } else if let include = config.includeOnlyAssetIds, !include.isEmpty {
                fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(include), options: fetchOptions)
            } else {
                fetchResult = PHAsset.fetchAssets(with: fetchOptions)
            }
            let skipIds = config.skipAssetIds ?? []

            let total   = fetchResult.count
            let scanned = Counter()

            // Coalesces per-asset emitResult / emitProgress channel events into batched
            // "results" events + throttled "progress" events. Reduces IPC by ~50–100×.
            let batcher = EventBatcher(sink: eventSink, intervalMs: 100, maxBatch: 50)

            // Checkpoint support
            let checkpointKey = "nsfw_scan_checkpoint"
            let checkpoint    = CheckpointWriter(key: checkpointKey, everyN: 25)
            var startIndex    = 0
            if config.resumeFromCheckpoint,
               let savedId = UserDefaults.standard.string(forKey: checkpointKey) {
                for i in 0..<total {
                    if fetchResult.object(at: i).localIdentifier == savedId {
                        startIndex = i + 1
                        break
                    }
                }
                scanned.set(startIndex)
                if startIndex > 0 {
                    NSLog("[NSFW] Resuming from checkpoint at index %d/%d", startIndex, total)
                    batcher.recordProgress(eventSink.buildProgressMap(
                        scanned: startIndex, total: total, isComplete: false), force: true)
                }
            }

            // Incremental-scan cache. When active, assets whose (localId, modelId,
            // modificationDate) match a cached entry are skipped (and optionally
            // replayed) instead of re-classified. Bulk-loaded once into memory for O(1) lookups.
            let cacheActive  = config.skipAlreadyScanned && !config.forceRescan
            let cacheModelId = config.modelId
            let fingerprints: [String: Int64] = {
                guard cacheActive else { return [:] }
                ScanCache.shared.openIfNeeded()
                return ScanCache.shared.loadFingerprints(modelId: cacheModelId)
            }()
            if cacheActive {
                NSLog("[NSFW] Cache active: %d fingerprints loaded for model %@",
                      fingerprints.count, cacheModelId)
            } else if config.forceRescan {
                ScanCache.shared.openIfNeeded()
                NSLog("[NSFW] forceRescan: cache will be overwritten")
            }

            // `maxConcurrent` is the *initial* cap; the inner loop reads
            // `effectiveConcurrency` each iteration so low-power / thermal
            // changes apply live. Prefetch is sized against the initial cap
            // (resizing the prefetch window on every load-factor change
            // would thrash the PHCachingImageManager).
            let initialConcurrent = max(1, config.concurrency)
            let maxConcurrent     = effectiveConcurrency
            let batchSize         = config.batchSize
            NSLog("[NSFW] Scanning %d assets, batchSize=%d, maxConcurrent=%d (base=%d, loadFactor=%.2f), inputSize=%d",
                  total - startIndex, batchSize, maxConcurrent,
                  initialConcurrent, DeviceLoadMonitor.shared.currentLoadFactor,
                  inputSize)

            // Prefetch — must use the same options ImageAnalyzer requests with, otherwise no cache hits.
            let prefetchBatchSize = initialConcurrent * 3
            let prefetchOpts = ImageAnalyzer.makeRequestOptions()
            let prefetchTargetSize = CGSize(width: inputSize, height: inputSize)

            // Sliding window: keep at most 2 prefetch windows alive in the cache.
            // When a 3rd window is requested, the oldest is freed via stopCachingImages,
            // so memory stays bounded regardless of library size.
            var activeWindows: [[PHAsset]] = []
            let maxActiveWindows = 2

            func prefetchAssets(from startIdx: Int) {
                let endIdx = min(startIdx + prefetchBatchSize, total)
                guard startIdx < endIdx else { return }
                var assets: [PHAsset] = []
                for i in startIdx..<endIdx { assets.append(fetchResult.object(at: i)) }
                cachingManager.startCachingImages(
                    for: assets, targetSize: prefetchTargetSize,
                    contentMode: .aspectFill, options: prefetchOpts
                )
                activeWindows.append(assets)
                while activeWindows.count > maxActiveWindows {
                    let oldest = activeWindows.removeFirst()
                    cachingManager.stopCachingImages(
                        for: oldest, targetSize: prefetchTargetSize,
                        contentMode: .aspectFill, options: prefetchOpts
                    )
                }
            }

            prefetchAssets(from: startIndex)

            await withTaskGroup(of: Void.self) { group in
                var queued     = 0
                // Accumulates consecutive image assets to be submitted as one batch
                var imageBatch: [(index: Int, asset: PHAsset)] = []

                // Helper: flush the current imageBatch as one group task
                func flushImageBatch() {
                    guard !imageBatch.isEmpty else { return }
                    let batch = imageBatch
                    imageBatch = []
                    queued += 1
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        await self.processBatch(
                            assets:       batch,
                            engine:       engine,
                            analyzer:     analyzer,
                            total:        total,
                            scanned:      scanned,
                            checkpoint:   checkpoint,
                            batcher:      batcher
                        )
                    }
                }

                for index in startIndex..<total {
                    if (index - startIndex) % prefetchBatchSize == prefetchBatchSize / 2 {
                        prefetchAssets(from: index + prefetchBatchSize / 2)
                    }
                    guard !Task.isCancelled else {
                        imageBatch = []  // discard pending batch on cancel
                        break
                    }

                    let asset = fetchResult.object(at: index)

                    // Honour the Dart-side skip list — silently swallow the
                    // asset without emitting a result (progress counter still
                    // advances so the totals line up).
                    if skipIds.contains(asset.localIdentifier) {
                        flushImageBatch()
                        let s = scanned.increment()
                        batcher.recordProgress(eventSink.buildProgressMap(
                            scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                        continue
                    }

                    if cacheActive,
                       let cachedMod = fingerprints[asset.localIdentifier],
                       cachedMod == Self.modificationMs(asset) {
                        if let rec = ScanCache.shared.cachedRecord(
                            localIdentifier: asset.localIdentifier,
                            modelId: cacheModelId,
                            modificationDateMs: cachedMod) {
                            let labels = Self.decodeLabels(rec.labelsJson)
                            let cls = NsfwClassification(labels: labels)
                            UploadQueue.shared.submit(
                                asset: asset,
                                classification: cls,
                                modelId: self.config.modelId,
                                minConfidence: Float(self.config.confidenceThreshold)
                            )
                            if self.config.replayCachedResults {
                                var map = eventSink.buildResultMap(
                                    asset: asset, classification: cls)
                                map["fromCache"] = true
                                map[ChannelConstants.EventKey.scannedAt] = rec.scannedAtMs
                                batcher.recordResult(map)
                            }
                        }
                        let s = scanned.increment()
                        batcher.recordProgress(eventSink.buildProgressMap(
                            scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                        continue
                    }

                    // Skip Live Photo duplicates if configured
                    if asset.mediaSubtypes.contains(.photoLive) && !config.includeLivePhotos {
                        flushImageBatch()  // don't mix live-photo skip with pending batch
                        let s = scanned.increment()
                        batcher.recordProgress(eventSink.buildProgressMap(
                            scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                        continue
                    }

                    if asset.mediaType == .image || asset.mediaType == .unknown {
                        // Accumulate into batch
                        imageBatch.append((index, asset))
                        if imageBatch.count >= batchSize {
                            if queued >= effectiveConcurrency {
                                await group.next()
                                queued -= 1
                            }
                            flushImageBatch()
                        }

                    } else {
                        // Videos: flush any pending image batch first, then dispatch video individually
                        if queued >= effectiveConcurrency {
                            await group.next()
                            queued -= 1
                        }
                        flushImageBatch()

                        if queued >= effectiveConcurrency {
                            await group.next()
                            queued -= 1
                        }
                        queued += 1
                        group.addTask { [weak self] in
                            guard let self = self, !Task.isCancelled else { return }
                            do {
                                let frames = try await sampler.sample(asset: asset, config: self.config, inputSize: inputSize)
                                let classification: NsfwClassification
                                if frames.isEmpty {
                                    NSLog("[NSFW] Video SKIPPED (no usable frames): %@ duration=%.2fs",
                                          asset.localIdentifier, asset.duration)
                                    batcher.recordResult(self.eventSink.buildResultMap(
                                        asset: asset, classification: .unknown, status: "skipped",
                                        errorMessage: "no usable frames (duration=\(String(format: "%.2f", asset.duration))s)"))
                                    let s = scanned.increment()
                                    batcher.recordProgress(self.eventSink.buildProgressMap(
                                        scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                                    return
                                }
                                classification = try await self.classifyFrames(
                                    frames: frames, engine: engine, aggregator: aggregator
                                )
                                batcher.recordResult(self.eventSink.buildResultMap(
                                    asset: asset, classification: classification))
                                UploadQueue.shared.submit(
                                    asset: asset,
                                    classification: classification,
                                    modelId: self.config.modelId,
                                    minConfidence: Float(self.config.confidenceThreshold)
                                )
                                checkpoint.record(asset.localIdentifier)
                                ScanCache.shared.record(
                                    localIdentifier: asset.localIdentifier,
                                    modelId: self.config.modelId,
                                    modificationDateMs: Self.modificationMs(asset),
                                    scannedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                    labelsJson: Self.encodeLabels(classification.labels)
                                )
                            } catch {
                                let msg = "\(error)"
                                NSLog("[NSFW] Video FAILED: %@ — %@", asset.localIdentifier, msg)
                                batcher.recordResult(self.eventSink.buildResultMap(
                                    asset: asset, classification: .unknown, status: "failed", errorMessage: msg))
                            }
                            let s = scanned.increment()
                            batcher.recordProgress(self.eventSink.buildProgressMap(
                                scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                        }
                    }
                }

                // Tail-flush: remaining images that didn't fill a full batch
                if !imageBatch.isEmpty {
                    if queued >= effectiveConcurrency {
                        await group.next()
                        queued -= 1
                    }
                    flushImageBatch()
                }

                await group.waitForAll()
            }

            cachingManager.stopCachingImagesForAllAssets()
            activeWindows.removeAll()

            let finalCount = scanned.value
            if finalCount == total || Task.isCancelled {
                batcher.recordProgress(eventSink.buildProgressMap(
                    scanned: finalCount, total: total, isComplete: !Task.isCancelled))
                if Task.isCancelled {
                    checkpoint.flush()
                } else {
                    checkpoint.clear()
                }
            } else {
                checkpoint.flush()
            }
            // Final flush — guarantees no pending results/progress are lost.
            batcher.flush()
            ScanCache.shared.flush()

        } catch {
            // Errors in the do-block typically fire before any results are batched
            // (model load, fetch options) — no flush needed.
            eventSink.emitError(code: "SCAN_ERROR", message: error.localizedDescription)
        }
    }

    // MARK: - Batch image processing

    /// Loads pixel buffers for all assets in the batch concurrently, then submits
    /// them to the engine as a single classifyBatch() call. Falls back to
    /// individual classify() calls on any engine-level error.
    /// Guarantees exactly one emitResult + one scanned.increment() per asset.
    private func processBatch(
        assets:     [(index: Int, asset: PHAsset)],
        engine:     MLEngine,
        analyzer:   ImageAnalyzer,
        total:      Int,
        scanned:    Counter,
        checkpoint: CheckpointWriter,
        batcher:    EventBatcher
    ) async {
        guard !assets.isEmpty else { return }

        // 1. Load pixel buffers concurrently; record failures immediately.
        //    Capture the underlying error so it surfaces in Dart logs instead
        //    of the opaque "pixelBuffer unavailable" message.
        //    SendablePixelBuffer lets us cross the TaskGroup boundary cleanly
        //    under Swift 6 strict concurrency — CVPixelBuffer itself isn't Sendable.
        var orderedBuffers: [CVPixelBuffer?] = Array(repeating: nil, count: assets.count)
        var bufferErrors:   [String?]        = Array(repeating: nil, count: assets.count)
        let region = config.roi
        await withTaskGroup(of: (Int, SendablePixelBuffer?, String?).self) { group in
            for (i, pair) in assets.enumerated() {
                group.addTask {
                    do {
                        let buf = try await analyzer.pixelBuffer(for: pair.asset, region: region)
                        return (i, SendablePixelBuffer(buf), nil)
                    } catch {
                        let desc = "\(type(of: error)): \(error.localizedDescription)"
                        return (i, nil, desc)
                    }
                }
            }
            for await (i, wrapped, err) in group {
                orderedBuffers[i] = wrapped?.value
                bufferErrors[i]   = err
            }
        }

        // Assets that failed pixel-buffer loading are emitted as failed right away
        var validPairs: [(assetIndex: Int, asset: PHAsset, buffer: CVPixelBuffer)] = []
        for (i, pair) in assets.enumerated() {
            if let buf = orderedBuffers[i] {
                validPairs.append((i, pair.asset, buf))
            } else {
                let reason = bufferErrors[i] ?? "renderToPooledBuffer returned nil"
                NSLog("[NSFW] Asset FAILED (pixelBuffer): %@ — %@",
                      pair.asset.localIdentifier, reason)
                batcher.recordResult(eventSink.buildResultMap(
                    asset: pair.asset, classification: .unknown,
                    status: "failed", errorMessage: "pixelBuffer unavailable: \(reason)"))
                let s = scanned.increment()
                batcher.recordProgress(eventSink.buildProgressMap(
                    scanned: s, total: total, isComplete: s == total, currentAsset: pair.asset))
            }
        }

        guard !validPairs.isEmpty else { return }

        // 2. Batch inference (or per-asset fallback on error)
        let buffers = validPairs.map { $0.buffer }
        var classifications: [NsfwClassification]

        do {
            classifications = try await engine.classifyBatch(buffers)
            guard classifications.count == validPairs.count else {
                throw MLEngineError.batchSizeMismatch(expected: validPairs.count, got: classifications.count)
            }
        } catch {
            NSLog("[NSFW] Batch classify error (%d assets): %@ — per-asset fallback",
                  validPairs.count, error.localizedDescription)
            classifications = []
            for buf in buffers {
                let c = (try? await engine.classify(pixelBuffer: buf)) ?? .unknown
                classifications.append(c)
            }
        }

        // 3. Emit results
        let scannedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        for (i, pair) in validPairs.enumerated() {
            let classification = classifications[i]
            batcher.recordResult(eventSink.buildResultMap(
                asset: pair.asset, classification: classification))
            UploadQueue.shared.submit(
                asset: pair.asset,
                classification: classification,
                modelId: self.config.modelId,
                minConfidence: Float(self.config.confidenceThreshold)
            )
            checkpoint.record(pair.asset.localIdentifier)
            ScanCache.shared.record(
                localIdentifier: pair.asset.localIdentifier,
                modelId: self.config.modelId,
                modificationDateMs: Self.modificationMs(pair.asset),
                scannedAtMs: scannedAtMs,
                labelsJson: Self.encodeLabels(classification.labels)
            )
            let s = scanned.increment()
            batcher.recordProgress(eventSink.buildProgressMap(
                scanned: s, total: total, isComplete: s == total, currentAsset: pair.asset))
        }
    }

    // MARK: - Cache helpers

    /// Asset's modification date in epoch ms. Falls back to creation date, then to 0,
    /// so that an asset without dates yields a stable but unmatchable fingerprint
    /// (will never cache-hit, but won't crash).
    fileprivate static func modificationMs(_ asset: PHAsset) -> Int64 {
        let date = asset.modificationDate ?? asset.creationDate
        guard let date = date else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    fileprivate static func encodeLabels(_ labels: [NsfwClassification.Label]) -> String {
        let arr: [[String: Any]] = labels.map {
            ["category": $0.category, "confidence": Double($0.confidence)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let str  = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    fileprivate static func decodeLabels(_ json: String) -> [NsfwClassification.Label] {
        guard let data = json.data(using: .utf8),
              let arr  = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let cat  = dict["category"]   as? String,
                  let conf = dict["confidence"] as? Double else { return nil }
            return NsfwClassification.Label(category: cat, confidence: Float(conf))
        }
    }

    // MARK: - Detection-mode scan (NudeNet bounding-box pipeline)

    /// Detection-mode parallel of `runScan()`. Reuses the same checkpoint /
    /// progress / cache / event-batcher plumbing but routes pixel buffers
    /// through `MLDetectorEngine.detect(...)` and converts the boxes into a
    /// classifier-shaped `NsfwClassification` so the rest of the pipeline
    /// (UploadQueue, EventBatcher, ScanCache) keeps working unchanged.
    ///
    /// Videos are not supported in detection mode in Phase B — we run the
    /// detector on the first sampled frame and report that. (The hard-coded
    /// per-frame detector can grow into proper aggregation in a later phase.)
    private func runDetectionScan() async throws {
        NSLog("[NSFW] Starting DETECTION scan with model: %@", config.modelId)
        let engine = try await ModelRegistry.shared.detectorEngine(
            for: config.modelId, computeUnits: config.computeUnits
        )
        engine.setMinConfidence(Float(config.detectionConfidenceThreshold))
        let inputSize  = engine.descriptor.metadata["inputSize"] as? Int ?? 320
        let sampler    = VideoFrameSampler(
            enablePerceptualDedupe: true,
            region: config.roi
        )

        let cachingManager = PHCachingImageManager()
        cachingManager.allowsCachingHighQualityImages = false
        let analyzer = ImageAnalyzer(inputSize: inputSize, imageManager: cachingManager)

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !config.includeVideos {
            fetchOptions.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
        }
        let fetchResult: PHFetchResult<PHAsset>
        if let ids = config.assetIdentifiers {
            fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: fetchOptions)
        } else if let include = config.includeOnlyAssetIds, !include.isEmpty {
            fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: Array(include), options: fetchOptions)
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }
        let skipIds = config.skipAssetIds ?? []

        let total   = fetchResult.count
        let scanned = Counter()
        let batcher = EventBatcher(sink: eventSink, intervalMs: 100, maxBatch: 50)
        let checkpointKey = "nsfw_scan_checkpoint"
        let checkpoint    = CheckpointWriter(key: checkpointKey, everyN: 25)

        let cacheActive  = config.skipAlreadyScanned && !config.forceRescan
        let cacheModelId = config.modelId
        let fingerprints: [String: Int64] = {
            guard cacheActive else { return [:] }
            ScanCache.shared.openIfNeeded()
            return ScanCache.shared.loadFingerprints(modelId: cacheModelId)
        }()

        await withTaskGroup(of: Void.self) { group in
            var queued = 0
            for index in 0..<total {
                guard !Task.isCancelled else { break }
                let asset = fetchResult.object(at: index)

                // Skip-list filter — matches the classifier-path behaviour.
                if skipIds.contains(asset.localIdentifier) {
                    let s = scanned.increment()
                    batcher.recordProgress(eventSink.buildProgressMap(
                        scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                    continue
                }

                if cacheActive,
                   let cachedMod = fingerprints[asset.localIdentifier],
                   cachedMod == Self.modificationMs(asset) {
                    if let rec = ScanCache.shared.cachedRecord(
                        localIdentifier: asset.localIdentifier,
                        modelId: cacheModelId,
                        modificationDateMs: cachedMod) {
                        let labels = Self.decodeLabels(rec.labelsJson)
                        let detections = Self.decodeDetections(rec.detectionsJson)
                        let cls = NsfwClassification(labels: labels, detections: detections)
                        UploadQueue.shared.submit(
                            asset: asset,
                            classification: cls,
                            modelId: self.config.modelId,
                            minConfidence: Float(self.config.confidenceThreshold)
                        )
                        if config.replayCachedResults {
                            var map = eventSink.buildResultMap(asset: asset, classification: cls)
                            map["fromCache"] = true
                            map[ChannelConstants.EventKey.scannedAt] = rec.scannedAtMs
                            batcher.recordResult(map)
                        }
                    }
                    let s = scanned.increment()
                    batcher.recordProgress(eventSink.buildProgressMap(
                        scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                    continue
                }

                if asset.mediaSubtypes.contains(.photoLive) && !config.includeLivePhotos {
                    let s = scanned.increment()
                    batcher.recordProgress(eventSink.buildProgressMap(
                        scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                    continue
                }

                if queued >= effectiveConcurrency {
                    await group.next()
                    queued -= 1
                }
                queued += 1
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    do {
                        let buffer: CVPixelBuffer
                        if asset.mediaType == .video {
                            let frames = try await sampler.sample(asset: asset, config: self.config, inputSize: inputSize)
                            guard let first = frames.first else {
                                NSLog("[NSFW] Detection video SKIPPED (no frames): %@ duration=%.2fs",
                                      asset.localIdentifier, asset.duration)
                                batcher.recordResult(self.eventSink.buildResultMap(
                                    asset: asset, classification: .unknown, status: "skipped",
                                    errorMessage: "no usable frames (duration=\(String(format: "%.2f", asset.duration))s)"))
                                let s = scanned.increment()
                                batcher.recordProgress(self.eventSink.buildProgressMap(
                                    scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                                return
                            }
                            buffer = first
                        } else {
                            buffer = try await analyzer.pixelBuffer(
                                for: asset, region: self.config.roi)
                        }
                        let raw = try await engine.detect(pixelBuffer: buffer)
                        let cls = NsfwClassification.fromDetections(raw)

                        let scannedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                        batcher.recordResult(self.eventSink.buildResultMap(
                            asset: asset, classification: cls))
                        UploadQueue.shared.submit(
                            asset: asset,
                            classification: cls,
                            modelId: self.config.modelId,
                            minConfidence: Float(self.config.confidenceThreshold)
                        )
                        checkpoint.record(asset.localIdentifier)
                        ScanCache.shared.record(
                            localIdentifier: asset.localIdentifier,
                            modelId: self.config.modelId,
                            modificationDateMs: Self.modificationMs(asset),
                            scannedAtMs: scannedAtMs,
                            labelsJson: Self.encodeLabels(cls.labels),
                            detectionsJson: Self.encodeDetections(cls.detections)
                        )
                    } catch {
                        let msg = "\(error)"
                        NSLog("[NSFW] Detection FAILED: %@ — %@", asset.localIdentifier, msg)
                        batcher.recordResult(self.eventSink.buildResultMap(
                            asset: asset, classification: .unknown,
                            status: "failed", errorMessage: msg))
                    }
                    let s = scanned.increment()
                    batcher.recordProgress(self.eventSink.buildProgressMap(
                        scanned: s, total: total, isComplete: s == total, currentAsset: asset))
                }
            }
            await group.waitForAll()
        }

        let finalCount = scanned.value
        batcher.recordProgress(eventSink.buildProgressMap(
            scanned: finalCount, total: total, isComplete: !Task.isCancelled), force: true)
        if Task.isCancelled {
            checkpoint.flush()
        } else {
            checkpoint.clear()
        }
        batcher.flush()
        ScanCache.shared.flush()
    }

    fileprivate static func encodeDetections(_ detections: [NsfwClassification.BodyPartDetection]?) -> String? {
        guard let detections = detections, !detections.isEmpty else { return nil }
        let arr: [[String: Any]] = detections.map { $0.toDictionary() }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let str  = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }

    fileprivate static func decodeDetections(_ json: String?) -> [NsfwClassification.BodyPartDetection]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        let result: [NsfwClassification.BodyPartDetection] = arr.compactMap { dict in
            let label = (dict["label"] as? String) ?? (dict["className"] as? String) ?? ""
            guard let conf = dict["confidence"] as? Double else { return nil }
            let category = (dict["aggregatedCategory"] as? String) ?? (dict["category"] as? String) ?? "unknown"
            let box = (dict["box"] as? [String: Any]) ?? dict
            let x = (box["x"] as? Double) ?? 0
            let y = (box["y"] as? Double) ?? 0
            let w = (box["width"] as? Double) ?? 0
            let h = (box["height"] as? Double) ?? 0
            return NsfwClassification.BodyPartDetection(
                className: label, category: category, confidence: Float(conf),
                x: Float(x), y: Float(y), width: Float(w), height: Float(h)
            )
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Video frame classification

    private func classifyFrames(
        frames:     [CVPixelBuffer],
        engine:     MLEngine,
        aggregator: VideoResultAggregator
    ) async throws -> NsfwClassification {
        // Legacy "definitely NSFW" hard-threshold — caps the loop at any
        // single frame ≥ 0.9 confidence regardless of category.
        let hardThreshold: Float = 0.9
        // Task #18 — early exit when a non-"safe" frame crosses 0.95.
        // Gated by `earlyExitOnHighConfidence` in case a host wants
        // exhaustive scoring (e.g. analytics) over a fast verdict.
        let earlyExitThreshold: Float = 0.95
        let earlyExitEnabled = config.earlyExitOnHighConfidence
        let batchSize = config.batchSize
        var results: [NsfwClassification] = []

        outer: for chunkStart in stride(from: 0, to: frames.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let chunkEnd = min(chunkStart + batchSize, frames.count)
            let chunk    = Array(frames[chunkStart..<chunkEnd])

            let batchResults: [NsfwClassification]
            do {
                batchResults = try await engine.classifyBatch(chunk)
            } catch {
                // Fallback: classify individually
                var fallback: [NsfwClassification] = []
                for frame in chunk {
                    fallback.append((try? await engine.classify(pixelBuffer: frame)) ?? .unknown)
                }
                batchResults = fallback
            }

            // Inspect results one-by-one so the early-exit check fires on
            // the exact triggering frame rather than after the whole batch
            // has been appended.
            for r in batchResults {
                results.append(r)
                let top = r.topLabel
                // #18 — non-safe NSFW verdict with very high confidence.
                if earlyExitEnabled,
                   top.category != "safe",
                   top.category != "unknown",
                   top.confidence > earlyExitThreshold {
                    NSLog("[NSFW] Video early-exit (category=%@, confidence=%.3f)",
                          top.category, top.confidence)
                    break outer
                }
                // Legacy any-category hard-threshold fast exit.
                if top.confidence >= hardThreshold {
                    break outer
                }
            }
        }

        return aggregator.aggregate(results)
    }
}

/// Coalesces per-asset events into batched channel messages.
/// - Results are accumulated and flushed every `intervalMs` or when `maxBatch` reached,
///   whichever comes first, as a single `"results"` event with an `items` array.
/// - Progress events are throttled to at most one per `intervalMs`. Only the latest
///   pending progress dict is kept — intermediate updates are dropped.
/// - `flush()` forces an immediate send of anything pending (call at end of scan / on cancel).
private final class EventBatcher: @unchecked Sendable {
    private let sink: ScanEventSink
    private let intervalMs: Int
    private let maxBatch: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "nsfw.eventbatcher")

    private var pendingResults: [[String: Any]] = []
    private var pendingProgress: [String: Any]?
    private var scheduled = false

    init(sink: ScanEventSink, intervalMs: Int = 100, maxBatch: Int = 50) {
        self.sink = sink
        self.intervalMs = intervalMs
        self.maxBatch = maxBatch
    }

    func recordResult(_ event: [String: Any]) {
        lock.lock()
        pendingResults.append(event)
        let shouldFlushNow = pendingResults.count >= maxBatch
        lock.unlock()
        if shouldFlushNow { flush() } else { scheduleFlush() }
    }

    func recordProgress(_ event: [String: Any], force: Bool = false) {
        lock.lock()
        pendingProgress = event
        lock.unlock()
        if force { flush() } else { scheduleFlush() }
    }

    func flush() {
        lock.lock()
        let results = pendingResults
        let progress = pendingProgress
        pendingResults.removeAll(keepingCapacity: true)
        pendingProgress = nil
        scheduled = false
        lock.unlock()

        if !results.isEmpty {
            // Order: results before the progress that reflects them, so the Dart side
            // never sees "scanned=N" before the N-th result has arrived.
            sink.emitResults(results)
        }
        if let p = progress {
            sink.emit(p)
        }
    }

    private func scheduleFlush() {
        lock.lock()
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(intervalMs)) { [weak self] in
            self?.flush()
        }
    }
}

/// Throttled checkpoint writer — coalesces UserDefaults writes during scan.
/// Resume granularity is `everyN` assets (re-scans up to N items on crash recovery).
private final class CheckpointWriter: @unchecked Sendable {
    private let key: String
    private let everyN: Int
    private var counter = 0
    private var pending: String?
    private let lock = NSLock()

    init(key: String, everyN: Int = 25) {
        self.key = key
        self.everyN = everyN
    }

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        pending = id
        counter += 1
        if counter >= everyN {
            UserDefaults.standard.set(id, forKey: key)
            counter = 0
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if let id = pending {
            UserDefaults.standard.set(id, forKey: key)
            counter = 0
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
        counter = 0
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Thread-safe counter for parallel scan progress tracking.
/// Uses `OSAllocatedUnfairLock` (iOS 16+) — cheaper than `NSLock` under contention.
private final class Counter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { state.withLock { $0 } }

    func set(_ v: Int) { state.withLock { $0 = v } }

    @discardableResult
    func increment() -> Int { state.withLock { $0 += 1; return $0 } }
}
