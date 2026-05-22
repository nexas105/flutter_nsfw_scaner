import AVFoundation
import Foundation
import os

/// Owns the `AVCaptureSession`, the active `AVCaptureDeviceInput`, and the
/// chosen output preset for the live camera scan. Created lazily by
/// `ScanMethodHandler` on `startCameraScan` and discarded on `stopCameraScan`
/// — one instance per scan, never reused.
///
/// IOS-CAM-01 lands the start lifecycle: permission gate, device input,
/// session preset selection. IOS-CAM-02 attaches `AVCaptureVideoDataOutput`.
/// IOS-CAM-08 adds `stop()`.
/// Thread-safety: all mutable state (`session`, `videoOutput`, `deviceInput`,
/// `isRunning`) is mutated exclusively on `outputQueue`. The published
/// session-preview hop runs on `MainActor`. `@unchecked Sendable` is correct
/// because the queue+actor discipline replaces what the type system would
/// otherwise check.
final class CameraSessionTask: NSObject, @unchecked Sendable {

    private let config: CameraConfiguration
    private let eventSink: ScanEventSink
    let processor: CameraFrameProcessor

    let session = AVCaptureSession()
    let outputQueue = DispatchQueue(label: "nsfw.camera.output", qos: .userInitiated)

    var videoOutput: AVCaptureVideoDataOutput?
    var deviceInput: AVCaptureDeviceInput?

    private(set) var isRunning = false

    /// Set `true` by `stop()` — synchronously, before any `await` — so a
    /// `start()` still in flight (e.g. awaiting the permission prompt)
    /// observes it and refuses to publish a session the caller has already
    /// torn down. Lock-protected: written from the arbitrary task that calls
    /// `stop()`, read on both `outputQueue` and the `MainActor`.
    private let stopRequestedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var stopRequested: Bool {
        get { stopRequestedLock.withLock { $0 } }
        set { stopRequestedLock.withLock { $0 = newValue } }
    }

    /// `AVCaptureSession` interruption / runtime-error observers. Registered
    /// once the session is running, removed on `stop()`/`deinit`. Mutated
    /// only on `outputQueue`.
    private var sessionObservers: [NSObjectProtocol] = []

    init(config: CameraConfiguration, eventSink: ScanEventSink, processor: CameraFrameProcessor) {
        self.config = config
        self.eventSink = eventSink
        self.processor = processor
    }

    // MARK: - Lifecycle

    /// Returns `true` once the session is running and ready to deliver
    /// sample buffers. Returns `false` when the camera could not be brought
    /// up (permission denied, no back camera, configuration rejected) —
    /// the caller is expected to release the slot it reserved in
    /// `ScanMethodHandler.startCameraScan` so a future call can succeed.
    /// An appropriate error event has already been emitted by the time this
    /// returns false; the caller does NOT need to surface a second one.
    @discardableResult
    func start() async -> Bool {
        // Permission gate — IOS-CAM-07. Bails after emitting the appropriate
        // stream event if the host can't (or won't) grant access.
        guard await ensureCameraAuthorized() else { return false }

        // Configure AND start on the dedicated output queue. Apple's docs
        // require `startRunning` to share the queue used for
        // `beginConfiguration`/`commitConfiguration`; running it off-queue
        // races with `removeInput/removeOutput` during stop() (H11).
        let configured: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            outputQueue.async { [weak self] in
                guard let self = self else { cont.resume(returning: false); return }
                guard !self.stopRequested else { cont.resume(returning: false); return }
                let ok = self.configureSession()
                if ok {
                    self.session.startRunning()
                    self.isRunning = true
                    self.registerSessionObservers()
                }
                cont.resume(returning: ok)
            }
        }

        guard configured else {
            // No need to publish the session for preview — it's not live.
            return false
        }

        // WIDGET-01 cross-phase contract — publish the configured session so
        // the Phase-04 `NsfwCameraPreviewFactory` can attach
        // `AVCaptureVideoPreviewLayer` to the same session the analyzer is
        // already feeding from. One session, two outputs (data + preview).
        // Re-check `stopRequested` first: a `stop()` that landed while this
        // `start()` was awaiting permission/configuration sets the flag
        // *before* it enqueues its `clear()` on the MainActor. So if we read
        // `false` here, our `set` was enqueued before that `clear` and the
        // serial MainActor runs `clear` last — the registry never ends up
        // publishing a session `stop()` has already torn down.
        let publishedSession = session
        await MainActor.run {
            guard !self.stopRequested else { return }
            CameraPreviewRegistry.shared.set(session: publishedSession)
        }
        return true
    }

    /// Tear down the capture session, release the device input, drain any
    /// in-flight inference, and idempotently mark the task stopped.
    /// `ScanMethodHandler` discards the instance after this call returns —
    /// restart works because each `startCameraScan` builds a fresh task.
    func stop() async {
        // Mark stopped *before* any await — a `start()` still in flight must
        // see this and skip publishing the session for preview (see start()).
        stopRequested = true
        // Tell the processor too: an inference that outlives drainInflight's
        // timeout must not emit into the torn-down session / event sink.
        processor.markStopped()

        // WIDGET-01 cross-phase contract — clear the published session so
        // any active `NsfwCameraPreviewView` detaches its preview layer
        // before we tear the session down.
        await MainActor.run {
            CameraPreviewRegistry.shared.clear()
        }

        // 1. Stop the capture session — no more sample buffers will arrive.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            outputQueue.async { [weak self] in
                guard let self = self else { cont.resume(); return }
                // stopRequested is already set synchronously at the top of
                // stop(); detach the interruption observers regardless of
                // whether a session was ever brought up.
                self.removeSessionObservers()
                guard self.isRunning || self.videoOutput != nil || self.deviceInput != nil else {
                    cont.resume()
                    return
                }
                self.isRunning = false
                // Detach the sample-buffer delegate first so a final
                // in-flight callback can't land mid-teardown (H13).
                self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
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

        // 3. Finalize + upload any covert recording. Runs strictly after
        //    drainInflight so no inference can still be appending frames to
        //    the recorder. No-op when nothing was recorded.
        await processor.finishRecording()
    }

    /// Returns `true` when a device input was successfully added and the
    /// session is ready for `startRunning()`; `false` otherwise. The caller
    /// MUST NOT call `startRunning()` when this returns `false` — doing so
    /// flips `isRunning` to true with no live input, leaving the camera slot
    /// permanently squatted in `ScanMethodHandler`.
    private func configureSession() -> Bool {
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
            return false
        }
        guard session.canAddInput(input) else {
            eventSink.emit([
                ChannelConstants.EventKey.eventType: ChannelConstants.EventType.cameraError,
                ChannelConstants.EventKey.message:   "Camera input rejected by capture session",
            ])
            return false
        }
        session.addInput(input)
        deviceInput = input

        attachVideoDataOutput()  // IOS-CAM-02 fills this in.
        return true
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
        case "medium":
            // 960×540 — closest iOS preset to Android CamcorderProfile.QUALITY_480P.
            // Keeps "medium" visibly distinct from "low" (was collapsing to VGA).
            userPreset = .iFrame960x540
        default:
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

    // MARK: - Interruption / runtime-error recovery

    /// Registers observers for `AVCaptureSession` interruption and runtime
    /// errors. iOS interrupts the capture session whenever the app is
    /// backgrounded, or another app / a phone call takes the camera; without
    /// an `.interruptionEnded` handler the preview stays frozen because
    /// nobody calls `startRunning()` again. Runs on `outputQueue`.
    private func registerSessionObservers() {
        let nc = NotificationCenter.default

        let interrupted = nc.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            NSLog("[NSFW] CameraSessionTask: session interrupted (%@)",
                  String(describing: reason))
        }

        let resumed = nc.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            self?.restartIfNeeded(context: "interruption ended")
        }

        let runtimeError = nc.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil
        ) { [weak self] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            NSLog("[NSFW] CameraSessionTask: runtime error: %@",
                  err?.localizedDescription ?? "unknown")
            self?.restartIfNeeded(context: "runtime error")
        }

        sessionObservers = [interrupted, resumed, runtimeError]
    }

    /// Removes the interruption / runtime-error observers. Idempotent.
    private func removeSessionObservers() {
        let nc = NotificationCenter.default
        for observer in sessionObservers { nc.removeObserver(observer) }
        sessionObservers.removeAll()
    }

    /// Restarts `startRunning()` on `outputQueue` when the scan is still
    /// logically active but the session has stopped (interrupted / errored).
    private func restartIfNeeded(context: String) {
        outputQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.stopRequested, self.isRunning, !self.session.isRunning else { return }
            self.session.startRunning()
            NSLog("[NSFW] CameraSessionTask: session restarted after %@", context)
        }
    }

    deinit {
        // Belt-and-braces — stop() normally clears these first.
        let nc = NotificationCenter.default
        for observer in sessionObservers { nc.removeObserver(observer) }
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
