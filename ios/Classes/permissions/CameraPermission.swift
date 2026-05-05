import AVFoundation
import Foundation

/// Thin async wrapper around `AVCaptureDevice` authorization for `.video`.
/// Mirrors `PhotoLibraryPermission` so the camera path has a single,
/// centralised place to read / request capture permission from.
struct CameraPermission {

    static func currentStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Returns the resolved status. Resolves `.notDetermined` by triggering
    /// the system permission prompt and translating the boolean result back
    /// into `.authorized` / `.denied`.
    static func requestIfNeeded() async -> AVAuthorizationStatus {
        let status = currentStatus()
        if status != .notDetermined { return status }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }

    static var isGranted: Bool {
        currentStatus() == .authorized
    }

    /// Pre-flight check for `NSCameraUsageDescription`. Without this key the
    /// host app's `Info.plist` Apple aborts the process when
    /// `requestAccess(for: .video)` is called the first time. We surface a
    /// useful error event instead of letting the host crash.
    static var hostHasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }
}
