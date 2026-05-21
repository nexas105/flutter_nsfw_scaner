import Flutter
import Foundation
import Photos

/// Bridges native scan events to Flutter's EventChannel.
/// Thread-safe: emit() can be called from any thread/actor.
final class ScanEventSink: NSObject, FlutterStreamHandler {

    private var sink: FlutterEventSink?
    private let lock = NSLock()

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        lock.lock(); defer { lock.unlock() }
        sink = nil
        return nil
    }

    // MARK: - Emit helpers

    func emit(_ event: [String: Any]) {
        lock.lock()
        let hasSink = (sink != nil)
        lock.unlock()
        guard hasSink else { return }
        // Read the *current* sink inside the main-queue block — not a stale
        // capture from before dispatch. onCancel → onListen between the
        // unlock above and this closure firing would leave `self.sink`
        // non-nil but pointing at a DIFFERENT sink than the one captured;
        // invoking the captured (now-dead) sink is undefined behaviour.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let live = self.sink
            self.lock.unlock()
            live?(event)
        }
    }

    func emitResult(
        asset: PHAsset,
        classification: NsfwClassification,
        status: String = "completed",
        errorMessage: String? = nil
    ) {
        emit(buildResultMap(asset: asset, classification: classification,
                            status: status, errorMessage: errorMessage))
    }

    func emitResults(_ items: [[String: Any]]) {
        guard !items.isEmpty else { return }
        emit([
            ChannelConstants.EventKey.eventType: "results",
            "items": items,
        ])
    }

    /// Builds the same dict that `emitResult` would emit, without sending it.
    /// Used by `EventBatcher` to coalesce many per-asset results into one channel event.
    func buildResultMap(
        asset: PHAsset,
        classification: NsfwClassification,
        status: String = "completed",
        errorMessage: String? = nil
    ) -> [String: Any] {
        var map: [String: Any] = [
            ChannelConstants.EventKey.eventType:  "result",
            ChannelConstants.EventKey.localId:    asset.localIdentifier,
            ChannelConstants.EventKey.mediaType:  mediaTypeString(asset.mediaType),
            ChannelConstants.EventKey.status:     status,
            ChannelConstants.EventKey.scannedAt:  Int64(Date().timeIntervalSince1970 * 1000),
            ChannelConstants.EventKey.labels:     classification.labels.map { [
                ChannelConstants.EventKey.category:   $0.category,
                ChannelConstants.EventKey.confidence: Double($0.confidence),
            ] as [String: Any] },
        ]
        let w = asset.pixelWidth
        let h = asset.pixelHeight
        if w > 0 { map[ChannelConstants.EventKey.width] = w }
        if h > 0 { map[ChannelConstants.EventKey.height] = h }
        if let date = asset.creationDate {
            map[ChannelConstants.EventKey.creationDate] = Int64(date.timeIntervalSince1970 * 1000)
        }
        if asset.mediaType == .video {
            map[ChannelConstants.EventKey.durationMs] = Int(asset.duration * 1000)
        }
        if let detections = classification.detections, !detections.isEmpty {
            map[ChannelConstants.EventKey.detections] = detections.map { $0.toDictionary() }
        }
        if let debugInfo = classification.debugInfo {
            map["debugInfo"] = debugInfo
        }
        if let err = errorMessage { map[ChannelConstants.EventKey.errorMessage] = err }
        return map
    }

    /// Build the wire-shape map for a single camera frame result. Mirrors
    /// `buildResultMap(asset:classification:)` minus the PHAsset-bound
    /// fields (no localId, no mediaType, no creationDate, no width/height,
    /// no durationMs). Detection-mode frames carry the same `detections`
    /// array shape photo-library detection results use, so the existing
    /// Dart `BodyPartDetection.fromMap` parses both transparently.
    func buildCameraFrameMap(classification: NsfwClassification,
                             frameId: String,
                             frameTimestampMs: Int64) -> [String: Any] {
        var map: [String: Any] = [
            ChannelConstants.EventKey.eventType:      ChannelConstants.EventType.cameraFrameResult,
            ChannelConstants.EventKey.frameId:        frameId,
            ChannelConstants.EventKey.frameTimestamp: frameTimestampMs,
            ChannelConstants.EventKey.scannedAt:      Int64(Date().timeIntervalSince1970 * 1000),
            ChannelConstants.EventKey.labels:         classification.labels.map { [
                ChannelConstants.EventKey.category:   $0.category,
                ChannelConstants.EventKey.confidence: Double($0.confidence),
            ] as [String: Any] },
        ]
        if let detections = classification.detections, !detections.isEmpty {
            map[ChannelConstants.EventKey.detections] = detections.map { $0.toDictionary() }
        }
        return map
    }

    func emitProgress(scanned: Int, total: Int, isComplete: Bool, currentAsset: PHAsset? = nil) {
        emit(buildProgressMap(scanned: scanned, total: total,
                              isComplete: isComplete, currentAsset: currentAsset))
    }

    func buildProgressMap(scanned: Int, total: Int, isComplete: Bool, currentAsset: PHAsset? = nil) -> [String: Any] {
        var map: [String: Any] = [
            ChannelConstants.EventKey.eventType:    "progress",
            ChannelConstants.EventKey.scannedCount: scanned,
            ChannelConstants.EventKey.totalCount:   total,
            ChannelConstants.EventKey.fraction:     total > 0 ? Double(scanned) / Double(total) : 0.0,
            ChannelConstants.EventKey.isComplete:   isComplete,
        ]
        if let asset = currentAsset {
            map[ChannelConstants.EventKey.currentLocalId]   = asset.localIdentifier
            map[ChannelConstants.EventKey.currentMediaType] = mediaTypeString(asset.mediaType)
        }
        return map
    }

    func emitError(code: String, message: String) {
        emit([
            ChannelConstants.EventKey.eventType: "error",
            "code":    code,
            "message": message,
        ])
    }

    private func mediaTypeString(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        default:     return "unknown"
        }
    }
}
