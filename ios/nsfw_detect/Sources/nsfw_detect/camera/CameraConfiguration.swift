import Foundation

/// Swift mirror of Dart `CameraConfiguration`. Built from the channel-map
/// produced by `CameraConfiguration.toChannelMap()` on the Dart side
/// (see `lib/src/api/camera_configuration.dart`). Defaults are kept in
/// lock-step with the Dart defaults — fps=2 in particular, which matches
/// the milestone success criterion.
struct CameraConfiguration {
    let modelId: String
    let confidenceThreshold: Double
    /// `"classification"` | `"detection"` — wire value of `ScanMode`.
    let mode: String
    /// 1...30, default 2.
    let fps: Int
    /// `"low"` | `"medium"` | `"high"` — wire value of `CameraResolution`.
    let resolution: String
    let detectionConfidenceThreshold: Double
    let iouThreshold: Double
    let iosComputeUnits: ComputeUnitsPreference

    /// Optional normalised ROI rect (top-left origin, all in [0, 1]) applied
    /// to every captured frame before the model resize. `nil` = no crop.
    let roi: RoiCropper.Region?

    init(from dict: [String: Any]) {
        modelId             = dict["modelId"] as? String ?? ModelIds.openNsfw2
        confidenceThreshold = dict["confidenceThreshold"] as? Double ?? 0.7
        mode                = (dict["mode"] as? String) ?? "classification"
        fps                 = max(1, min(30, dict["fps"] as? Int ?? 2))
        resolution          = (dict["resolution"] as? String) ?? "medium"
        detectionConfidenceThreshold = dict["detectionConfidenceThreshold"] as? Double ?? 0.25
        iouThreshold        = dict["iouThreshold"] as? Double ?? 0.45
        if let cuRaw = dict["iosComputeUnits"] as? String,
           let parsed = ComputeUnitsPreference(rawValue: cuRaw) {
            iosComputeUnits = parsed
        } else {
            iosComputeUnits = .all
        }
        roi = RoiCropper.Region.from(map: dict["roi"] as? [String: Any])
    }
}
