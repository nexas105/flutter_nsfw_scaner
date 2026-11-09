import Foundation

/// Aggregates multiple per-frame NsfwClassification results into one video-level result.
/// Strategy: hard-threshold fast exit + Gaussian-weighted average for borderline content.
final class VideoResultAggregator {

    private let hardThreshold: Float = 0.9

    func aggregate(_ classifications: [NsfwClassification]) -> NsfwClassification {
        guard !classifications.isEmpty else { return .unknown }

        // Fast path: one frame is clearly positive on an *unsafe* label.
        // The `safe` / `unknown` categories are excluded — otherwise a single
        // confidently-safe frame would short-circuit the whole video to safe,
        // even when later frames are NSFW (false negative).
        if let definite = classifications.first(where: {
            $0.topLabel.confidence >= hardThreshold
                && $0.topLabel.category != "safe"
                && $0.topLabel.category != "unknown"
        }) {
            return definite
        }

        // Weighted average for borderline content. Frames are weighted with a
        // Gaussian centred on the middle of the video — title cards and
        // fade-to-black transitions sit at the edges and get less weight,
        // without being zeroed out. Mirrors the Android VideoResultAggregator
        // (formula from task brief #7); both platforms now agree.
        let n = classifications.count
        let center = Double(n) / 2.0
        let sigma = max(1.0, Double(n) / 4.0)
        let twoSigmaSq = 2.0 * sigma * sigma

        // Per-category weight sums are tracked separately so a category that
        // only appears in some frames (e.g. a brief detection) is normalised
        // against the frames it actually appeared in — not the whole video,
        // which would dilute it toward zero.
        var weightedSums: [String: Float] = [:]
        var weightOfCategory: [String: Float] = [:]

        for (index, result) in classifications.enumerated() {
            let dx = Double(index) - center
            let weight = Float(1.0 + 0.5 * exp(-(dx * dx) / twoSigmaSq))
            for label in result.labels {
                weightedSums[label.category, default: 0] += label.confidence * weight
                weightOfCategory[label.category, default: 0] += weight
            }
        }

        let normalized: [String: Float] = weightedSums.reduce(into: [:]) { acc, entry in
            let (category, sum) = entry
            if let w = weightOfCategory[category], w > 0 {
                acc[category] = sum / w
            }
        }
        let sorted = normalized.sorted { $0.value > $1.value }
        let labels = sorted.map {
            NsfwClassification.Label(category: $0.key, confidence: $0.value)
        }

        return NsfwClassification(labels: labels)
    }
}
