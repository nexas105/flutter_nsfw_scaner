import AVFoundation
import Flutter
import UIKit

/// `FlutterPlatformViewFactory` for the live camera preview consumed by the
/// Dart-side `NsfwCameraView` widget (Phase 04, WIDGET-01).
///
/// View-type id (must match the Dart side):
/// `nsfw_detect_ios/camera_preview`
///
/// The factory does **not** create or own a capture session. It produces
/// `NsfwCameraPreviewView` instances that subscribe to `CameraPreviewRegistry`
/// and attach an `AVCaptureVideoPreviewLayer` to whatever session
/// `CameraSessionTask` has published.
///
/// Cross-phase contract:
/// - Phase 02 (`CameraSessionTask`) publishes `session` to the registry on
///   `start()` and clears it on `stop()`.
/// - Phase 04 (this file) only consumes the registry — it does not configure
///   inputs, outputs, or presets. The preview layer renders whatever the
///   shared session is producing.
@objc final class NsfwCameraPreviewFactory: NSObject, FlutterPlatformViewFactory {

    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = (args as? [String: Any]) ?? [:]
        return NsfwCameraPreviewView(
            frame: frame,
            viewId: viewId,
            params: params,
            messenger: messenger
        )
    }

    /// `creationParams` come over a `StandardMessageCodec` — see Dart side.
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` and binds it to whichever
/// `AVCaptureSession` is published by `CameraPreviewRegistry`. Keeps the
/// preview layer's frame in sync with the host view's bounds so
/// orientation / size changes are picked up automatically.
final class NsfwCameraPreviewView: NSObject, FlutterPlatformView {

    private let containerView: PreviewContainer
    private let previewLayer: AVCaptureVideoPreviewLayer
    private weak var observerToken: AnyObject?

    init(
        frame: CGRect,
        viewId: Int64,
        params: [String: Any],
        messenger: FlutterBinaryMessenger
    ) {
        self.containerView = PreviewContainer(frame: frame)
        self.previewLayer = AVCaptureVideoPreviewLayer()

        // Match the analyzer's aspect-fill crop so normalized [0,1] boxes
        // from `MLDetectorEngine` land correctly on the previewed pixels
        // (WIDGET-03 Option A).
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = containerView.bounds
        containerView.layer.addSublayer(previewLayer)
        containerView.previewLayer = previewLayer

        super.init()

        // Subscribe to the active-session publisher. Replays the current
        // value immediately so a view created mid-session paints without
        // waiting for the next start.
        Task { @MainActor in
            CameraPreviewRegistry.shared.addObserver(self)
        }

        _ = params  // currently unused; reserved for future knobs (zoom, etc.)
        _ = viewId
        _ = messenger
    }

    deinit {
        // Stay defensive — registry holds observers weakly, but explicit
        // removal prevents a stale callback during teardown.
        let layer = previewLayer
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            CameraPreviewRegistry.shared.removeObserver(self)
            layer.session = nil
        }
    }

    // MARK: - FlutterPlatformView

    func view() -> UIView { containerView }
}

extension NsfwCameraPreviewView: CameraPreviewRegistry.Observer {
    func cameraPreviewRegistry(didSet session: AVCaptureSession?) {
        // Layer mutation must happen on the main thread; we're already
        // marked `@MainActor` via the registry.
        previewLayer.session = session
    }
}

/// Small `UIView` subclass that resizes its child `AVCaptureVideoPreviewLayer`
/// when bounds change. Doing this in `layoutSubviews` (vs `frame.didSet`)
/// keeps rotations and Auto Layout host-app embeddings working without
/// extra wiring on the Flutter side.
private final class PreviewContainer: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
