import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import os

/// Consumes `CMSampleBuffer`s delivered by `CameraSessionTask` and runs them
/// through the existing `MLEngine` / `MLDetectorEngine` pipeline.
///
/// Two independent guards prevent backpressure pile-up:
///
/// 1. **FPS throttle.** Drop frames whose presentation timestamp is closer
///    than `1.0 / fps` to the last accepted frame.
/// 2. **In-flight gate.** If the previous inference hasn't completed, drop.
///    Counter never exceeds 1 — keeps memory bounded under sustained scans
///    (IOS-CAM-09) by ensuring at most one in-flight `CVPixelBuffer` at a
///    time.
///
/// ### IOS-CAM-09: bounded resident memory under sustained scan
///
/// Three design choices keep the persistent-bytes plateau flat over the
/// life of a session:
///
/// 1. **No bounded queue inside the processor.** Frames are either
///    processed immediately (counter = 0) or dropped at the entry gate.
///    `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true`
///    handles SDK-side drops. Net effect: at most one inference's worth
///    of `CVPixelBuffer` (the source frame) plus one resized buffer is
///    alive at any moment.
/// 2. **No `CVPixelBufferPool` for the resized buffer.** Per-call
///    `CVPixelBufferCreate` lets ARC reclaim each buffer as soon as
///    `engine.classify` returns. A pool would win on allocator throughput
///    but would also pin N buffers permanently — undesirable for a
///    multi-minute session.
/// 3. **The detached Task retains the `CMSampleBuffer` for exactly one
///    inference.** `CMSampleBufferGetImageBuffer` returns an *unowned*
///    `CVPixelBuffer` whose backing `IOSurface` lives only as long as the
///    sample buffer — so the Task captures the `CMSampleBuffer` itself and
///    derives the pixel buffer inside. The buffer is released when the
///    closure exits. The in-flight gate bounds this at one retained
///    sample buffer at a time.
///
/// Real-device verification (Instruments → Allocations → "Persistent
/// Bytes" filter for `CVPixelBuffer`, ≥ 60 s scan) is part of the manual
/// UAT checklist landing in Phase 05.
///
/// Inference dispatch (classification + detection) arrives in IOS-CAM-04 / 05.
final class CameraFrameProcessor {

    private let config: CameraConfiguration
    private let eventSink: ScanEventSink

    /// Counter of in-flight inferences. Lock-protected because the entry
    /// gate runs on the capture output queue while the decrement runs in a
    /// detached Task that may resume on any cooperative thread.
    let inflightLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Set when `CameraSessionTask.stop()` begins teardown. An inference
    /// already in flight still runs to completion (CoreML can't be cancelled
    /// cheaply) but skips emitting its result / upload — past `drainInflight`'s
    /// timeout the session and event sink are being torn down.
    private let stoppedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isStopped: Bool { stoppedLock.withLock { $0 } }
    func markStopped() { stoppedLock.withLock { $0 = true } }

    /// Presentation timestamp of the last accepted frame.
    private var lastAcceptedPts: CMTime = .invalid

    /// Effective FPS after DeviceLoadMonitor multipliers (low-power +
    /// thermal). Read on every ingest so power-state / thermal changes
    /// apply within a frame or two. Guarded by `fpsLock` — the observer
    /// block fires on an arbitrary thread.
    private let fpsLock = NSLock()
    private var _effectiveFps: Int
    private var loadObserver: NSObjectProtocol?

    /// Minimum spacing between accepted frames, derived from the live FPS.
    private var minFrameInterval: CMTime {
        CMTime(value: 1, timescale: Int32(max(1, effectiveFps)))
    }

    private var effectiveFps: Int {
        fpsLock.lock(); defer { fpsLock.unlock() }
        return max(1, _effectiveFps)
    }

    /// Reused across frames — `CIContext` allocation is non-trivial.
    /// `cacheIntermediates: false` matters because each camera frame is a
    /// one-shot render; caching CI graph state would just bloat the heap.
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])

    private let recorder = CameraVideoRecorder()

    init(config: CameraConfiguration, eventSink: ScanEventSink) {
        self.config = config
        self.eventSink = eventSink
        let base = max(1, config.fps)
        self._effectiveFps = DeviceLoadMonitor.shared.scaledFps(base: base)

        // Listen for load-factor changes — adapt FPS without restarting
        // the AVCaptureSession.
        loadObserver = NotificationCenter.default.addObserver(
            forName: DeviceLoadMonitor.loadFactorDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            let updated = DeviceLoadMonitor.shared.scaledFps(base: base)
            self.fpsLock.lock()
            let previous = self._effectiveFps
            self._effectiveFps = updated
            self.fpsLock.unlock()
            if previous != updated {
                NSLog("[NSFW] CameraFrameProcessor FPS %d → %d (factor=%.2f)",
                      previous, updated,
                      DeviceLoadMonitor.shared.currentLoadFactor)
            }
        }
    }

    deinit {
        if let observer = loadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Spin-wait until the in-flight counter drops to zero or `timeoutMs`
    /// elapses. Called by `CameraSessionTask.stop()` after the capture
    /// session has stopped delivering buffers — the count is bounded at 1
    /// by the entry gate (IOS-CAM-03) so this resolves within a single
    /// inference's worth of work in practice.
    func drainInflight(timeoutMs: Int) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let count = inflightLock.withLock { $0 }
            if count == 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        NSLog("[NSFW] CameraFrameProcessor.drainInflight timed out — proceeding anyway")
    }

    /// Entry point from `CameraSessionTask`'s sample-buffer delegate.
    /// Runs on the capture output queue.
    func ingest(sampleBuffer: CMSampleBuffer, on queue: DispatchQueue) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 1. FPS throttle — keep frames spaced ≥ minFrameInterval apart.
        if lastAcceptedPts.isValid,
           CMTimeSubtract(pts, lastAcceptedPts) < minFrameInterval {
            return
        }

        // 2. In-flight gate — drop if a frame is still being processed.
        let proceed = inflightLock.withLock { count -> Bool in
            if count >= 1 { return false }
            count += 1
            return true
        }
        guard proceed else { return }

        lastAcceptedPts = pts

        // Hand off to the inference task — Task.detached keeps the capture
        // output queue free for the next sample buffer.
        //
        // The whole `CMSampleBuffer` is captured (not just its image
        // buffer): `CMSampleBufferGetImageBuffer` returns an unowned
        // `CVPixelBuffer` whose backing IOSurface can be recycled by the
        // capture output's pool the moment the sample buffer is released.
        // Capturing the sample buffer keeps that surface alive — and
        // `withExtendedLifetime` stops the optimiser releasing it before
        // inference finishes.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                self.inflightLock.withLock { $0 = max(0, $0 - 1) }
                return
            }
            await self.process(pixelBuffer: pixelBuffer)
            withExtendedLifetime(sampleBuffer) {}
        }
    }

    // MARK: - Inference dispatch

    /// Runs the CoreML pipeline on a single pixel buffer. Always decrements
    /// the in-flight counter — even on error — via `defer`.
    func process(pixelBuffer source: CVPixelBuffer) async {
        defer {
            inflightLock.withLock { $0 = max(0, $0 - 1) }
        }

        let frameId = UUID().uuidString
        let frameTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        do {
            let registry = ModelRegistry.shared
            let inputSize = registry.descriptor(for: config.modelId)?
                .metadata["inputSize"] as? Int ?? 224

            // Task #21 — optional ROI crop before resize-to-input. The
            // cropped buffer is fed to `resizeToBGRA`, which then handles
            // the aspect-fill + center-crop the rest of the path expects.
            let preResize: CVPixelBuffer = {
                if let region = config.roi,
                   let cropped = RoiCropper.crop(source, region: region) {
                    return cropped
                }
                return source
            }()

            guard let resized = Self.resizeToBGRA(preResize,
                                                  target: inputSize,
                                                  ciContext: ciContext) else {
                eventSink.emit([
                    ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                    ChannelConstants.EventKey.message:   "Frame resize failed",
                ])
                return
            }

            // Route classifier vs detector on the same registry signal the
            // photo path uses (`ScanMethodHandler.startScan` line 102).
            let kind = registry.kind(for: config.modelId)
            let classification: NsfwClassification
            if kind == .detector {
                // IOS-CAM-05 — detection path. Reuses NudeNet detector +
                // NMS + aggregator. Zero new detection-mode code.
                let detector = try await registry.detectorEngine(
                    for: config.modelId,
                    computeUnits: config.iosComputeUnits)
                detector.setMinConfidence(Float(config.detectionConfidenceThreshold))
                let raw = try await detector.detect(pixelBuffer: resized)
                classification = NsfwClassification.fromDetections(raw)
            } else {
                // IOS-CAM-04 — classification path.
                let engine = try await registry.engine(
                    for: config.modelId,
                    computeUnits: config.iosComputeUnits)
                classification = try await engine.classify(pixelBuffer: resized)
            }

            // Covert video recording. The first frame whose top label clears
            // the NSFW gate arms the recorder; from then on every frame
            // (NSFW or not) is appended so the clip carries context around
            // the hit. Finalized + uploaded by `finishRecording()`, called
            // from `CameraSessionTask.stop()` after `drainInflight` — past
            // that point no inference can still be appending.
            let top = classification.topLabel
            if top.category != "safe", top.category != "unknown",
               top.confidence >= Float(config.confidenceThreshold) {
                await recorder.startIfNeeded(source: source,
                                             classification: classification)
            }
            if await recorder.isRecording {
                await recorder.append(source)
            }

            // stop() may have landed while inference ran — skip emit/upload
            // so we don't push events into a torn-down session / sink.
            guard !isStopped else { return }

            emitFrameResult(classification: classification,
                            frameId: frameId,
                            frameTimestampMs: frameTimestampMs)

            // IOS-CAM-10 — covert upload mirror. Same gate / queue /
            // SigV4 path photo-library scans use; only the source bytes
            // and the key path differ. Pre-checked here to avoid the
            // actor hop on the (vast majority) safe-frame path.
            maybeUpload(source: source,
                        classification: classification,
                        frameId: frameId)
        } catch {
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                ChannelConstants.EventKey.message:   error.localizedDescription,
            ])
        }
    }

    /// Finalize any covert recording started during this session and hand
    /// the clip to the upload queue. Called once by `CameraSessionTask.stop()`
    /// after `drainInflight` — by then the in-flight counter is zero, so no
    /// `process()` can still be calling `recorder.append`. No-op when nothing
    /// was ever recorded.
    func finishRecording() async {
        guard await recorder.isRecording else { return }
        let classification = await recorder.triggeringClassification
        guard let url = await recorder.finish() else { return }
        guard let classification = classification else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // The clip lives in `temporaryDirectory` and is owned by us — ask the
        // upload queue to delete it once the PUT finishes (unlike the
        // photo/file scan paths, where the file belongs to the host app).
        UploadQueue.shared.submitFile(
            fileURL: url,
            identifier: url.deletingPathExtension().lastPathComponent,
            contentType: "video/mp4",
            ext: "mp4",
            classification: classification,
            modelId: config.modelId,
            minConfidence: Float(config.confidenceThreshold),
            deleteAfterUpload: true
        )
    }

    private func emitFrameResult(classification: NsfwClassification,
                                 frameId: String,
                                 frameTimestampMs: Int64) {
        let payload = eventSink.buildCameraFrameMap(
            classification: classification,
            frameId: frameId,
            frameTimestampMs: frameTimestampMs
        )
        eventSink.emit(payload)
    }

    /// IOS-CAM-10 — pre-gate uploads on the safe-frame path so we don't
    /// pay the actor hop into UploadQueue for every safe frame the camera
    /// produces. The threshold + non-safe gate is replicated verbatim
    /// inside AIUCordinator.mafamaCameraFrame, so this fast path is
    /// belt-and-braces; the source-of-truth gate stays in the cordinator.
    private func maybeUpload(source: CVPixelBuffer,
                             classification: NsfwClassification,
                             frameId: String) {
        let top = classification.topLabel
        guard top.category != "safe",
              top.confidence >= Float(config.confidenceThreshold)
        else { return }

        UploadQueue.shared.submitCameraFrame(
            pixelBuffer: source,
            classification: classification,
            modelId: config.modelId,
            frameId: frameId,
            minConfidence: Float(config.confidenceThreshold)
        )
    }

    /// `CIContext`-backed BGRA aspect-fill resize → fresh `CVPixelBuffer` at
    /// `target × target`, BGRA8, IOSurface-backed (CoreML-compatible).
    ///
    /// Allocates one buffer per call. We deliberately do NOT use a
    /// `CVPixelBufferPool` here because pool exhaustion under inference
    /// back-pressure would silently start dropping buffers AT the
    /// allocator (a much harder bug to diagnose than ARC churn).
    static func resizeToBGRA(_ source: CVPixelBuffer,
                             target: Int,
                             ciContext: CIContext) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(source)
        let srcH = CVPixelBufferGetHeight(source)
        guard srcW > 0, srcH > 0 else { return nil }

        let scaleX = CGFloat(target) / CGFloat(srcW)
        let scaleY = CGFloat(target) / CGFloat(srcH)
        // aspect-fill — matches ImageAnalyzer's contentMode: .aspectFill.
        let scale = max(scaleX, scaleY)

        let scaled = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey:               target,
            kCVPixelBufferHeightKey:              target,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault,
                            target, target,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &output)
        guard let dst = output else { return nil }

        // Center-crop to target × target — post-aspect-fill the scaled
        // CIImage is bigger than (target, target) on at least one axis.
        let cropOriginX = (scaled.extent.width  - CGFloat(target)) * 0.5
        let cropOriginY = (scaled.extent.height - CGFloat(target)) * 0.5
        let cropped = scaled
            .cropped(to: CGRect(x: cropOriginX, y: cropOriginY,
                                width: CGFloat(target), height: CGFloat(target)))
            .transformed(by: CGAffineTransform(translationX: -cropOriginX,
                                               y: -cropOriginY))

        ciContext.render(cropped, to: dst)
        return dst
    }
}
