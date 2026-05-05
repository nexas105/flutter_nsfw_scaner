import Foundation

struct NsfwClassification {
    struct Label {
        let category:   String  // "safe" | "suggestive" | "nudity" | "explicitNudity" | "unknown"
        let confidence: Float
    }

    /// Raw body part detection from object detection models. Wire shape is
    /// kept in lock-step with Dart `BodyPartDetection.fromMap`:
    /// `{ label, confidence, aggregatedCategory, box: {x, y, width, height} }`.
    /// Origin is top-left, all coordinates normalised to `[0, 1]`.
    struct BodyPartDetection {
        /// Raw class name from the detector (e.g. `FEMALE_BREAST_EXPOSED`).
        let className: String
        /// Canonical bucket — `safe | suggestive | nudity | explicitNudity | unknown`.
        let category: String
        let confidence: Float
        let x: Float        // top-left x, normalized [0, 1]
        let y: Float        // top-left y, normalized [0, 1]
        let width: Float
        let height: Float

        func toDictionary() -> [String: Any] {
            return [
                "label":              className,
                "confidence":         Double(confidence),
                "aggregatedCategory": category,
                "box": [
                    "x":      Double(x),
                    "y":      Double(y),
                    "width":  Double(width),
                    "height": Double(height),
                ] as [String: Any],
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

    /// Build an `NsfwClassification` from a list of detector boxes. Aggregates
    /// per-category confidence as `max(confidence)` across all boxes that map
    /// to the same `aggregatedCategory`, sorted descending. The resulting
    /// `labels` keep the existing `topCategory` / `topConfidence` semantics
    /// working for detection runs; the original boxes are stashed on
    /// `detections` for UI consumption.
    static func fromDetections(_ raw: [BodyPartDetectionNative]) -> NsfwClassification {
        if raw.isEmpty { return .empty }
        var perCategory: [String: Float] = [:]
        for det in raw {
            let prev = perCategory[det.aggregatedCategory] ?? 0
            if det.confidence > prev {
                perCategory[det.aggregatedCategory] = det.confidence
            }
        }

        // Sort by NSFW priority FIRST, then by confidence within each tier.
        // A high-confidence FACE_FEMALE (category "safe") must NOT outrank a
        // moderate-confidence FEMALE_BREAST_EXPOSED (category "nudity") when
        // deciding `topCategory` — the user wants "any explicit/nudity hit
        // → result is NSFW", regardless of how strongly the detector also saw
        // a face. Within the same tier, max confidence still wins.
        let categoryRank: [String: Int] = [
            "explicitNudity": 0,
            "nudity":         1,
            "suggestive":     2,
            "safe":           3,
            "unknown":        4,
        ]
        let labels = perCategory
            .map { Label(category: $0.key, confidence: $0.value) }
            .sorted { (a, b) in
                let ra = categoryRank[a.category] ?? Int.max
                let rb = categoryRank[b.category] ?? Int.max
                if ra != rb { return ra < rb }
                return a.confidence > b.confidence
            }

        // Map the native detection type onto the inner BodyPartDetection
        // wire-shape used by ScanEventSink.buildResultMap.
        let detections: [BodyPartDetection] = raw.map { d in
            BodyPartDetection(
                className:  d.label,
                category:   d.aggregatedCategory,
                confidence: d.confidence,
                x:          d.x,
                y:          d.y,
                width:      d.width,
                height:     d.height
            )
        }
        return NsfwClassification(labels: labels, detections: detections)
    }

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
