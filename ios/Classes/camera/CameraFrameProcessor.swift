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
/// Inference dispatch (classification + detection) arrives in IOS-CAM-04 / 05.
final class CameraFrameProcessor {

    private let config: CameraConfiguration
    private let eventSink: ScanEventSink

    /// Counter of in-flight inferences. Lock-protected because the entry
    /// gate runs on the capture output queue while the decrement runs in a
    /// detached Task that may resume on any cooperative thread.
    let inflightLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Presentation timestamp of the last accepted frame.
    private var lastAcceptedPts: CMTime = .invalid

    /// Minimum spacing between accepted frames, derived from `config.fps`.
    private var minFrameInterval: CMTime {
        CMTime(value: 1, timescale: Int32(max(1, config.fps)))
    }

    /// Reused across frames — `CIContext` allocation is non-trivial.
    /// `cacheIntermediates: false` matters because each camera frame is a
    /// one-shot render; caching CI graph state would just bloat the heap.
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])

    init(config: CameraConfiguration, eventSink: ScanEventSink) {
        self.config = config
        self.eventSink = eventSink
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            inflightLock.withLock { $0 = max(0, $0 - 1) }
            return
        }

        // Hand off to the inference task — Task.detached keeps the capture
        // output queue free for the next sample buffer.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.process(pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - Inference dispatch

    /// Runs the CoreML pipeline on a single pixel buffer. Always decrements
    /// the in-flight counter — even on error — via `defer`.
    func process(pixelBuffer source: CVPixelBuffer) async {
        defer {
            inflightLock.withLock { $0 = max(0, $0 - 1) }
        }

        do {
            let registry = ModelRegistry.shared
            let inputSize = registry.descriptor(for: config.modelId)?
                .metadata["inputSize"] as? Int ?? 224

            guard let resized = Self.resizeToBGRA(source,
                                                  target: inputSize,
                                                  ciContext: ciContext) else {
                eventSink.emit([
                    ChannelConstants.EventKey.eventType: "cameraError",
                    "message": "Frame resize failed",
                ])
                return
            }

            // IOS-CAM-04 — classification path. Detection lands in IOS-CAM-05.
            let engine = try await registry.engine(for: config.modelId,
                                                   computeUnits: config.iosComputeUnits)
            _ = try await engine.classify(pixelBuffer: resized)

            // IOS-CAM-06 wires emission of the result onto the EventChannel.
        } catch {
            eventSink.emit([
                ChannelConstants.EventKey.eventType: "cameraError",
                "message": "\(error)",
            ])
        }
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
