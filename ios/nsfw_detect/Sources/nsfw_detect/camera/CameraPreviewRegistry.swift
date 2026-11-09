import AVFoundation
import Foundation

/// Cross-cutting registry that publishes the *currently active*
/// `AVCaptureSession` so the Flutter `PlatformView` factory can attach an
/// `AVCaptureVideoPreviewLayer` to the same session that
/// `CameraFrameProcessor` is already consuming frames from.
///
/// This avoids running two independent capture sessions (one for ML,
/// one for the preview) which would double the camera-input cost,
/// halve the available bandwidth on older devices, and break
/// `AVCaptureMultiCamSession` budget on iOS.
///
/// Lifecycle:
/// - `CameraSessionTask.start()` calls `set(session:)` after the session
///   is configured but before `startRunning()` is observed by clients.
/// - `CameraSessionTask.stop()` calls `clear()` before tearing the
///   session down.
/// - The `NsfwCameraPreviewView` listens on `addObserver(_:)`; new
///   observers receive the current session immediately if one is set.
///
/// The registry is intentionally main-actor-isolated (preview-layer
/// mutation is main-thread anyway), so observers can safely touch
/// UIKit without dispatching.
@MainActor
final class CameraPreviewRegistry {

    static let shared = CameraPreviewRegistry()

    private init() {}

    private var currentSession: AVCaptureSession?
    private var observers: [WeakObserver] = []

    // MARK: - Observer protocol

    /// `NsfwCameraPreviewView` adopts this protocol — the registry holds
    /// observers weakly so the view's deinit drops the reference.
    protocol Observer: AnyObject {
        func cameraPreviewRegistry(didSet session: AVCaptureSession?)
    }

    private struct WeakObserver {
        weak var ref: Observer?
    }

    // MARK: - Producer side (`CameraSessionTask`)

    func set(session: AVCaptureSession) {
        currentSession = session
        prune()
        for o in observers { o.ref?.cameraPreviewRegistry(didSet: session) }
    }

    func clear() {
        currentSession = nil
        prune()
        for o in observers { o.ref?.cameraPreviewRegistry(didSet: nil) }
    }

    // MARK: - Consumer side (`NsfwCameraPreviewView`)

    var session: AVCaptureSession? { currentSession }

    func addObserver(_ observer: Observer) {
        prune()
        // Avoid duplicate registration.
        if observers.contains(where: { $0.ref === observer }) { return }
        observers.append(WeakObserver(ref: observer))
        // Immediate replay so a view created mid-session paints right away.
        observer.cameraPreviewRegistry(didSet: currentSession)
    }

    func removeObserver(_ observer: Observer) {
        observers.removeAll { $0.ref === observer || $0.ref == nil }
    }

    private func prune() {
        observers.removeAll { $0.ref == nil }
    }
}
