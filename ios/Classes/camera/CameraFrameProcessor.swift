import AVFoundation
import CoreVideo
import Foundation

/// Consumes `CMSampleBuffer`s delivered by `CameraSessionTask` and runs them
/// through the existing `MLEngine` / `MLDetectorEngine` pipeline. Owns the
/// FPS throttle, in-flight inference gate, BGRA resize, and result emission.
///
/// IOS-CAM-01 lands the skeleton (init + no-op `ingest`) so
/// `CameraSessionTask` can hold a reference. FPS throttling, the in-flight
/// counter, the resize, and the actual inference dispatch arrive in
/// IOS-CAM-03 / 04 / 05.
final class CameraFrameProcessor {

    private let config: CameraConfiguration
    private let eventSink: ScanEventSink

    init(config: CameraConfiguration, eventSink: ScanEventSink) {
        self.config = config
        self.eventSink = eventSink
    }

    /// Receives a fresh sample buffer from the capture session. Wired up in
    /// IOS-CAM-03; for now this is a deliberate no-op so the skeleton
    /// `CameraSessionTask` can run without crashing the host when frames
    /// start flowing before the rest of the pipeline lands.
    func ingest(sampleBuffer: CMSampleBuffer, on queue: DispatchQueue) {
        // Implemented in IOS-CAM-03.
    }
}
