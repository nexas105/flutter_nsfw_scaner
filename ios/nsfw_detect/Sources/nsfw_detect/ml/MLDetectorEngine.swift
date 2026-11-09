import Foundation
import CoreVideo

/// Sibling protocol to `MLEngine` for object-detection (bounding-box) models
/// like NudeNet. Same lifecycle (load / unload / configure) but produces
/// `[BodyPartDetectionNative]` per pixel buffer instead of a categorical
/// `NsfwClassification`.
///
/// Pendant to `android/.../ml/MLDetectorEngine.kt`.
protocol MLDetectorEngine: AnyObject {
    var descriptor: ModelDescriptorNative { get }

    /// Load the model into memory (idempotent).
    func load() async throws

    /// Free memory.
    func unload()

    /// Run detection on one pixel buffer.
    func detect(pixelBuffer: CVPixelBuffer) async throws -> [BodyPartDetectionNative]

    /// Batched variant. Default is serial.
    func detectBatch(_ buffers: [CVPixelBuffer]) async throws -> [[BodyPartDetectionNative]]

    /// Hint preferred compute units before `load()`. No-op default.
    func setPreferredComputeUnits(_ units: ComputeUnitsPreference)

    /// What the loaded model was actually built with. `.all` until loaded.
    var loadedComputeUnits: ComputeUnitsPreference { get }

    /// Optional confidence floor — boxes with `confidence < min` are dropped
    /// before being returned. `0` means "do not filter". No-op default.
    func setMinConfidence(_ min: Float)
}

extension MLDetectorEngine {
    func detectBatch(_ buffers: [CVPixelBuffer]) async throws -> [[BodyPartDetectionNative]] {
        var results: [[BodyPartDetectionNative]] = []
        results.reserveCapacity(buffers.count)
        for buf in buffers {
            results.append(try await detect(pixelBuffer: buf))
        }
        return results
    }

    func setPreferredComputeUnits(_ units: ComputeUnitsPreference) { /* default no-op */ }
    var loadedComputeUnits: ComputeUnitsPreference { .all }
    func setMinConfidence(_ min: Float) { /* default no-op */ }
}

/// Single bounding-box detection. Mirrors Dart `BodyPartDetection`.
/// `box` is normalised `[0, 1]` with origin **top-left** (caller is
/// responsible for converting from Vision's bottom-left origin).
struct BodyPartDetectionNative {
    let label: String          // raw NudeNet class, e.g. "FEMALE_BREAST_EXPOSED"
    let confidence: Float
    let x: Float               // top-left x, normalised
    let y: Float               // top-left y, normalised
    let width: Float
    let height: Float
    let aggregatedCategory: String  // "safe" | "suggestive" | "nudity" | "explicitNudity" | "unknown"

    func toDictionary() -> [String: Any] {
        return [
            "label":              label,
            "confidence":         Double(confidence),
            "aggregatedCategory": aggregatedCategory,
            "box": [
                "x":      Double(x),
                "y":      Double(y),
                "width":  Double(width),
                "height": Double(height),
            ] as [String: Any],
        ]
    }

    /// Maps a raw NudeNet class label to the canonical `NsfwCategory.name`
    /// string used everywhere else in the pipeline. Mirrors
    /// `BodyPartDetection.aggregateCategoryFromLabel` on the Dart side.
    static func aggregateCategory(forLabel rawLabel: String) -> String {
        let normalized = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        switch normalized {
        case "FEMALE_GENITALIA_EXPOSED", "MALE_GENITALIA_EXPOSED", "ANUS_EXPOSED":
            return "explicitNudity"
        case "FEMALE_BREAST_EXPOSED", "MALE_BREAST_EXPOSED", "BUTTOCKS_EXPOSED":
            return "nudity"
        case "FEMALE_GENITALIA_COVERED", "FEMALE_BREAST_COVERED",
             "BUTTOCKS_COVERED", "ANUS_COVERED":
            return "suggestive"
        case "FACE_FEMALE", "FACE_MALE",
             "FEET_EXPOSED", "FEET_COVERED",
             "BELLY_EXPOSED", "BELLY_COVERED",
             "ARMPITS_EXPOSED", "ARMPITS_COVERED":
            return "safe"
        default:
            return "unknown"
        }
    }
}
