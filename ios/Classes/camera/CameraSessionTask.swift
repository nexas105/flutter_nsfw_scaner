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
                ChannelConstants.EventKey.eventType: "cameraError",
                "message": "No camera device available for position .back",
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
                ChannelConstants.EventKey.eventType: "cameraError",
                "message": "Host app missing NSCameraUsageDescription in Info.plist",
            ])
            return false
        }
        let status = await CameraPermission.requestIfNeeded()
        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            eventSink.emit([
                ChannelConstants.EventKey.eventType: "cameraPermissionDenied",
                "message": "Camera access denied",
            ])
            return false
        case .notDetermined:
            // requestIfNeeded resolves notDetermined to authorized/denied —
            // unreachable in practice, but the compiler still requires a path.
            eventSink.emit([
                ChannelConstants.EventKey.eventType: "cameraError",
                "message": "Permission state unresolved",
            ])
            return false
        @unknown default:
            return false
        }
    }

    /// IOS-CAM-02 wires `AVCaptureVideoDataOutput`; placeholder lives here
    /// so `configureSession()` compiles without an extra empty-method dance.
    func attachVideoDataOutput() {
        // Implemented in IOS-CAM-02.
    }
}
