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
}
