import Foundation
import CoreML

/// User-selectable preference for which compute units CoreML should use.
/// Mirrors `MLComputeUnits`. Wire values come from Dart `IosComputeUnits.wireValue`.
enum ComputeUnitsPreference: String {
    case all
    case cpuAndNeuralEngine
    case cpuAndGPU
    case cpuOnly

    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all:                return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU:          return .cpuAndGPU
        case .cpuOnly:            return .cpuOnly
        }
    }
}

struct ScanConfiguration {
    let modelId: String
    let confidenceThreshold: Double
    let maxVideoFrames: Int
    let videoFrameInterval: Double
    let includeVideos: Bool
    let includeLivePhotos: Bool
    let assetIdentifiers: [String]?
    let resumeFromCheckpoint: Bool
    let concurrency: Int
    let detectionConfidenceThreshold: Double
    let iouThreshold: Double
    /// When true, CoreMLEngine skips batch prediction and uses the Vision
    /// per-image path. Use as a remote kill switch if batch misbehaves on a
    /// specific device family.
    let disableBatchPrediction: Bool

    /// When true, assets that match a cached `(localId, modelId, modificationDate)`
    /// triple are skipped (and optionally replayed via the cache) instead of re-scanned.
    /// Cuts re-sync time from minutes to seconds for large libraries.
    let skipAlreadyScanned: Bool
    /// Bypasses the cache for this run — every asset is re-scanned and the cache is
    /// overwritten. Useful for "rescan all" buttons and debug builds.
    let forceRescan: Bool
    /// When `skipAlreadyScanned` triggers a hit, replay the cached classification as
    /// a normal `result` event so the Dart stream stays complete. Disable to suppress
    /// cached results entirely (delta mode — only freshly scanned items reach Dart).
    let replayCachedResults: Bool
    /// Preferred CoreML compute units. Defaults to `.all`.
    let computeUnits: ComputeUnitsPreference

    /// Native scan mode. `"classification"` (default) routes through
    /// `MLEngine`; `"detection"` routes through `MLDetectorEngine`. Wire value
    /// originates from Dart `ScanMode.wireValue`.
    let mode: String

    /// Optional normalised ROI rect (top-left origin, all in [0, 1]) that the
    /// analyzer crops the source frame to before resizing for the model.
    /// `nil` means "no crop". Passed by Dart as
    /// `roi: {x, y, width, height}` on scan/startScan calls.
    let roi: RoiCropper.Region?

    /// Video early-exit gate. When true, the per-frame classifier loop in
    /// `ScanSessionTask.classifyFrames` short-circuits as soon as a frame
    /// returns top-confidence > 0.95 with category != "safe". Default true.
    let earlyExitOnHighConfidence: Bool

    /// Photo-library filtering by `PHAsset.localIdentifier`. Both are
    /// optional and additive — `skipAssetIds` is subtracted from the
    /// fetched set, then `includeOnlyAssetIds` (if non-empty) restricts
    /// the result. Mirrors the args the Dart agent is wiring up.
    let skipAssetIds: Set<String>?
    let includeOnlyAssetIds: Set<String>?

    /// Number of assets / video frames submitted per CoreML batch call.
    /// Derived from concurrency so no Dart-API change is needed.
    var batchSize: Int { max(1, concurrency) }

    init(from dict: [String: Any]) {
        modelId              = dict["modelId"] as? String ?? ModelIds.openNsfw2
        confidenceThreshold  = dict["confidenceThreshold"] as? Double ?? 0.7
        maxVideoFrames       = dict["maxVideoFrames"] as? Int ?? 8
        videoFrameInterval   = dict["videoFrameInterval"] as? Double ?? 2.0
        includeVideos        = dict["includeVideos"] as? Bool ?? true
        includeLivePhotos    = dict["includeLivePhotos"] as? Bool ?? true
        assetIdentifiers     = dict["assetIdentifiers"] as? [String]
        resumeFromCheckpoint = dict["resumeFromCheckpoint"] as? Bool ?? false
        concurrency          = dict["concurrency"] as? Int ?? 4
        detectionConfidenceThreshold = dict["detectionConfidenceThreshold"] as? Double ?? 0.25
        iouThreshold         = dict["iouThreshold"] as? Double ?? 0.45
        disableBatchPrediction = dict["disableBatchPrediction"] as? Bool ?? false
        skipAlreadyScanned   = dict["skipAlreadyScanned"] as? Bool ?? true
        forceRescan          = dict["forceRescan"] as? Bool ?? false
        replayCachedResults  = dict["replayCachedResults"] as? Bool ?? true
        if let cuRaw = dict["iosComputeUnits"] as? String,
           let parsed = ComputeUnitsPreference(rawValue: cuRaw) {
            computeUnits = parsed
        } else {
            computeUnits = .all
        }
        mode = (dict["mode"] as? String) ?? "classification"
        roi = RoiCropper.Region.from(map: dict["roi"] as? [String: Any])
        earlyExitOnHighConfidence = dict["earlyExitOnHighConfidence"] as? Bool ?? true
        if let raw = dict["skipAssetIds"] as? [String], !raw.isEmpty {
            skipAssetIds = Set(raw)
        } else {
            skipAssetIds = nil
        }
        if let raw = dict["includeOnlyAssetIds"] as? [String], !raw.isEmpty {
            includeOnlyAssetIds = Set(raw)
        } else {
            includeOnlyAssetIds = nil
        }
    }

    static let `default` = ScanConfiguration(from: [:])
}

enum ModelIds {
    static let openNsfw2    = "opennsfw2_coreml"
    static let falconsai    = "falconsai_nsfw"
    static let adamcodd     = "adamcodd_nsfw"
    /// Object-detection model — body-part bounding boxes, NudeNet-style.
    /// Registered as a `MLDetectorEngine`, not `MLEngine`.
    static let nudenet      = "nudenet"
}

enum ScanError: Error {
    case assetNotFound(String)
    case unsupportedMediaType
    case engineNotLoaded
    case frameSamplingFailed
}
