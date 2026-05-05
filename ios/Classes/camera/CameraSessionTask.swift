import AVFoundation
import Foundation

/// Owns the `AVCaptureSession`, the active `AVCaptureDeviceInput`, and the
/// chosen output preset for the live camera scan. Created lazily by
/// `ScanMethodHandler` on `startCameraScan` and discarded on `stopCameraScan`
/// — one instance per scan, never reused.
///
/// IOS-CAM-01 lands the start lifecycle: permission gate, device input,
/// session preset selection. IOS-CAM-02 attaches `AVCaptureVideoDataOutput`.
/// IOS-CAM-08 adds `stop()`.
final class CameraSessionTask: NSObject {

    private let config: CameraConfiguration
    private let eventSink: ScanEventSink
    let processor: CameraFrameProcessor

    let session = AVCaptureSession()
    let outputQueue = DispatchQueue(label: "nsfw.camera.output", qos: .userInitiated)

    var videoOutput: AVCaptureVideoDataOutput?
    var deviceInput: AVCaptureDeviceInput?

    private(set) var isRunning = false

    init(config: CameraConfiguration, eventSink: ScanEventSink, processor: CameraFrameProcessor) {
        self.config = config
        self.eventSink = eventSink
        self.processor = processor
    }

    // MARK: - Lifecycle

    func start() async {
        // Permission gate — IOS-CAM-07. Bails silently after emitting the
        // appropriate stream event if the host can't (or won't) grant access.
        guard await ensureCameraAuthorized() else { return }

        // Configure on the dedicated output queue to avoid blocking the
        // caller's actor (which on the iOS plugin happens to be the main
        // thread on the first hop into ScanMethodHandler).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputQueue.async { [weak self] in
                self?.configureSession()
                cont.resume()
            }
        }

        session.startRunning()
        isRunning = true
    }

    /// Tear down the capture session, release the device input, drain any
    /// in-flight inference, and idempotently mark the task stopped.
    /// `ScanMethodHandler` discards the instance after this call returns —
    /// restart works because each `startCameraScan` builds a fresh task.
    func stop() async {
        guard isRunning else { return }   // double-stop is a no-op (IOS-CAM-08)
        isRunning = false

        // 1. Stop the capture session — no more sample buffers will arrive.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputQueue.async { [weak self] in
                guard let self = self else { cont.resume(); return }
                self.session.stopRunning()
                self.session.beginConfiguration()
                if let out = self.videoOutput { self.session.removeOutput(out) }
                if let inp = self.deviceInput { self.session.removeInput(inp) }
                self.session.commitConfiguration()
                self.videoOutput = nil
                self.deviceInput = nil
                cont.resume()
            }
        }

        // 2. Drain any in-flight inference. The processor's counter is
        //    bounded at 1; spin-wait at 10ms ticks is fine here.
        await processor.drainInflight(timeoutMs: 2000)
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Session preset is the max of (caller's preset, model's required
        // minimum) so a user-selected `low` doesn't accidentally upscale into
        // NudeNet's 640 input.
        let inputSize = ModelRegistry.shared.descriptor(for: config.modelId)?
            .metadata["inputSize"] as? Int ?? 224
        session.sessionPreset = Self.preset(forUserPick: config.resolution,
                                            modelInputSize: inputSize)

        // Camera device — back lens. Phase 01 didn't surface a
        // `lensDirection` knob, so we hardcode `.back`. If a follow-up phase
        // adds the field, route it through here.
        let position: AVCaptureDevice.Position = .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                ChannelConstants.EventKey.message:   "No camera device available for position .back",
            ])
            return
        }
        if session.canAddInput(input) {
            session.addInput(input)
            deviceInput = input
        }

        attachVideoDataOutput()  // IOS-CAM-02 fills this in.
    }

    /// Maps Dart `CameraResolution` → `AVCaptureSession.Preset`, then bumps
    /// up if the active model demands more pixels than the user-selected
    /// preset would provide. NudeNet (640 input) requires at least 720p.
    static func preset(forUserPick pick: String,
                       modelInputSize: Int) -> AVCaptureSession.Preset {
        let userPreset: AVCaptureSession.Preset
        switch pick {
        case "low":
            // VGA — 640×480, already ≥ 224 width, fine for 224/384 classifiers.
            userPreset = .vga640x480
        case "high":
            userPreset = .hd1280x720
        default:
            // medium → VGA on iOS; we just need enough pixels to resize from.
            userPreset = .vga640x480
        }
        if modelInputSize >= 640 {
            return .hd1280x720
        }
        return userPreset
    }

    // MARK: - Permission

    private func ensureCameraAuthorized() async -> Bool {
        // Pre-flight: missing NSCameraUsageDescription crashes the host.
        guard CameraPermission.hostHasUsageDescription else {
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                ChannelConstants.EventKey.message:   "Host app missing NSCameraUsageDescription in Info.plist",
            ])
            return false
        }
        let status = await CameraPermission.requestIfNeeded()
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraPermissionDenied,
                ChannelConstants.EventKey.message:   "Camera access denied",
            ])
            return false
        case .notDetermined:
            // requestIfNeeded resolves notDetermined to authorized/denied —
            // unreachable in practice, but the compiler still requires a path.
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                ChannelConstants.EventKey.message:   "Permission state unresolved",
            ])
            return false
        @unknown default:
            return false
        }
    }

    /// Wires `AVCaptureVideoDataOutput` configured for BGRA8 (CoreML's
    /// native input format on iOS — no conversion needed before
    /// `MLEngine.classify(pixelBuffer:)`). Late frames are discarded by the
    /// SDK so the FPS throttle in `CameraFrameProcessor` (IOS-CAM-03) has
    /// authority over backpressure.
    func attachVideoDataOutput() {
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        out.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(out) {
            session.addOutput(out)
            videoOutput = out
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraSessionTask: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Hand the buffer straight to the processor — throttle and
        // in-flight gate live there (IOS-CAM-03).
        processor.ingest(sampleBuffer: sampleBuffer, on: outputQueue)
    }
}
