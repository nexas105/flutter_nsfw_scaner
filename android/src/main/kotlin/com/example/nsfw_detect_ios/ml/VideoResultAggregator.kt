package com.example.nsfw_detect_ios.ml

import kotlin.math.exp

/**
 * Collapses N per-frame results from a video into one video-level result.
 * Port of `ios/Classes/aggregator/VideoResultAggregator.swift`, adapted to
 * Android's `NsfwLabel` shape.
 *
 * Strategy:
 *  1. **Hard-threshold fast exit.** If any frame has a top-label confidence
 *     >= [HARD_THRESHOLD] (0.9 — picked to match iOS), return that frame's
 *     label list unchanged. Avoids dragging an "obviously NSFW" frame down
 *     by averaging it with safer surrounding frames.
 *  2. **Weighted average otherwise.** Per-category sum of
 *     `confidence * weight`, divided by total weight. Weights follow a
 *     Gaussian peak centred on the middle of the video:
 *
 *     ```
 *     w_i = 1.0 + 0.5 * exp(-((i - n/2)^2) / (2 * (n/4)^2))
 *     ```
 *
 *     This biases toward the actual content (title cards and fade-to-black
 *     transitions sit at the edges) without zeroing them out entirely.
 *
 * Why the formula differs slightly from the Swift version: iOS uses a
 * linear blend `1.0 - 0.3 * abs(position - 0.5) * 2`; this Android port
 * implements the Gaussian weighting specified in #7 of the task brief.
 * Behavioural difference at common frame counts is small (within ±5% of
 * relative weighting) — both bias the middle.
 */
object VideoResultAggregator {

    private const val HARD_THRESHOLD: Float = 0.9f

    /**
     * Aggregate classifier output across [frames] into a single label list.
     * Returns an empty list when [frames] is empty.
     */
    fun aggregate(frames: List<List<NsfwLabel>>): List<NsfwLabel> {
        if (frames.isEmpty()) return emptyList()

        // Fast path: one frame is clearly positive on its top label.
        for (frameLabels in frames) {
            val top = frameLabels.maxByOrNull { it.confidence } ?: continue
            if (top.confidence >= HARD_THRESHOLD) {
                return frameLabels.sortedByDescending { it.confidence }
            }
        }

        val n = frames.size
        val center = n / 2.0
        val sigma = maxOf(1.0, n / 4.0)
        val twoSigmaSq = 2.0 * sigma * sigma

        val weightedSums = HashMap<String, Float>()
        var totalWeight = 0f

        for ((i, frameLabels) in frames.withIndex()) {
            val dx = i - center
            val weight = (1.0 + 0.5 * exp(-(dx * dx) / twoSigmaSq)).toFloat()
            totalWeight += weight
            for (label in frameLabels) {
                val prev = weightedSums[label.category] ?: 0f
                weightedSums[label.category] = prev + label.confidence * weight
            }
        }

        if (totalWeight <= 0f) return emptyList()
        return weightedSums.entries
            .map { (cat, sum) -> NsfwLabel(cat, sum / totalWeight) }
            .sortedByDescending { it.confidence }
    }

    /**
     * Detection-mode variant: aggregate [BodyPartDetection] lists across
     * frames into a single wire-shape label list. Each frame is reduced to
     * its `[{category, confidence}, ...]` via [DetectionAggregator.aggregate],
     * then the per-frame result lists are passed through the
     * Gaussian-weighted average above.
     *
     * Returned shape matches the existing emit path so callers can use this
     * as a drop-in replacement for the "first-frame only" behaviour.
     */
    fun aggregateDetections(
        framesDetections: List<List<BodyPartDetection>>,
    ): List<Map<String, Any>> {
        if (framesDetections.isEmpty()) return emptyList()

        // Convert each frame's detections to a NsfwLabel list (max-per-category
        // already applied by DetectionAggregator) before averaging.
        val perFrameLabels: List<List<NsfwLabel>> = framesDetections.map { detections ->
            DetectionAggregator.aggregate(detections).map {
                NsfwLabel(
                    category = it["category"] as String,
                    confidence = (it["confidence"] as Double).toFloat(),
                )
            }
        }
        val merged = aggregate(perFrameLabels)
        return merged.map { mapOf("category" to it.category, "confidence" to it.confidence.toDouble()) }
    }
}
