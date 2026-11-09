import Photos
import Foundation

struct PhotoLibraryPermission {

    static func currentStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func request() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static var isGranted: Bool {
        let status = currentStatus()
        return status == .authorized || status == .limited
    }

    /// Pre-flight check for `NSPhotoLibraryUsageDescription`. The picker
    /// itself (`PHPickerViewController`) never reads it, but the plugin
    /// resolves `PHAsset` identifiers after the picker returns — and that
    /// path triggers iOS' TCC layer, which terminates the host process
    /// (SIGABRT) if the key is absent. Surface a clean error instead.
    static var hostHasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil
    }
}
