import Foundation

struct NsfwClassification {
    struct Label {
        let category:   String  // "safe" | "suggestive" | "nudity" | "explicitNudity" | "unknown"
        let confidence: Float
    }

    /// Raw body part detection from object detection models.
    struct BodyPartDetection {
        let className: String    // e.g. "FEMALE_BREAST_EXPOSED"
        let category: String     // "safe" | "nudity" | "explicitNudity" | "suggestive"
        let confidence: Float
        let x: Float             // bounding box center x (normalized 0-1 or raw pixels)
        let y: Float
        let width: Float
        let height: Float

        func toDictionary() -> [String: Any] {
            [
                "className": className,
                "category": category,
                "confidence": Double(confidence),
                "x": Double(x),
                "y": Double(y),
                "width": Double(width),
                "height": Double(height),
            ]
        }
    }

    let labels: [Label]  // sorted by confidence descending

    /// Raw body part detections from object detection models (nil for classifiers)
    let detections: [BodyPartDetection]?

    /// Debug diagnostics from inference (only populated when logging is enabled)
    var debugInfo: [String: Any]?

    init(labels: [Label], detections: [BodyPartDetection]? = nil, debugInfo: [String: Any]? = nil) {
        self.labels = labels
        self.detections = detections
        self.debugInfo = debugInfo
    }

    var topLabel: Label { labels.first ?? Label(category: "unknown", confidence: 0) }
    var isEmpty:  Bool  { labels.isEmpty }

    static let unknown = NsfwClassification(labels: [Label(category: "unknown", confidence: 1.0)], detections: nil)
    static let empty   = NsfwClassification(labels: [], detections: nil)

    /// Maps a Vision classification identifier to our canonical category name.
    static func canonicalCategory(_ identifier: String) -> String {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "safe", "sfw", "normal", "neutral", "drawing", "drawings", "non_nsfw":
            return "safe"
        case "suggestive", "sexy", "revealing", "questionable":
            return "suggestive"
        case "nudity", "nude", "nsfw", "porn":
            return "nudity"
        case "explicit", "explicit_nudity", "explicite", "pornographic", "hentai":
            return "explicitNudity"
        default:
            if normalized.hasPrefix("explicit")
                || normalized.contains("porn")
                || normalized.contains("hentai") {
                return "explicitNudity"
            }
            if normalized.hasPrefix("nude")
                || normalized.hasPrefix("nsfw")
                || normalized.hasPrefix("adult") {
                return "nudity"
            }
            if normalized.hasPrefix("safe")
                || normalized.hasPrefix("neutral")
                || normalized.hasPrefix("draw") {
                return "safe"
            }
            if normalized.hasPrefix("suggest")
                || normalized.hasPrefix("sex")
                || normalized.hasPrefix("reveal") {
                return "suggestive"
            }
            return "unknown"
        }
    }
}
