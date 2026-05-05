import Foundation

/// Aggregates multiple per-frame NsfwClassification results into one video-level result.
/// Strategy: hard-threshold fast exit + center-weighted average for borderline content.
final class VideoResultAggregator {

    private let hardThreshold: Float = 0.9

    func aggregate(_ classifications: [NsfwClassification]) -> NsfwClassification {
        guard !classifications.isEmpty else { return .unknown }

        // Fast path: one frame is clearly positive
        if let definite = classifications.first(where: { $0.topLabel.confidence >= hardThreshold }) {
            return definite
        }

        // Weighted average across all frames.
        // Center frames receive a higher weight to reduce false positives from
        // title cards and fade-to-black transitions.
        let count = Float(classifications.count)
        var weightedSums: [String: Float] = [:]
        var totalWeight:  Float = 0

        for (index, result) in classifications.enumerated() {
            let position = count > 1 ? Float(index) / (count - 1) : 0.5
            // Linear blend: weight is 1.0 at center, 0.7 at the edges.
            let weight: Float = 1.0 - 0.3 * abs(position - 0.5) * 2
            totalWeight += weight

            for label in result.labels {
                weightedSums[label.category, default: 0] += label.confidence * weight
            }
        }

        let normalized = weightedSums.mapValues { $0 / totalWeight }
        let sorted     = normalized.sorted { $0.value > $1.value }
        let labels     = sorted.map {
            NsfwClassification.Label(category: $0.key, confidence: $0.value)
        }

        return NsfwClassification(labels: labels)
    }
}
