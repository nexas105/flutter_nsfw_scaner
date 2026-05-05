import AVFoundation
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

        // Inference dispatch lands in IOS-CAM-04. Until then, decrement
        // immediately so the gate doesn't lock up the pipeline.
        inflightLock.withLock { $0 = max(0, $0 - 1) }
        _ = pixelBuffer  // referenced to suppress unused-let warning
    }
}
