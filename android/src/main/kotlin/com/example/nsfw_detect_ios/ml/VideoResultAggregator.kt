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
 *     `confidence * weight`, divided by the summed weight of the frames
 *     that category appeared in. Weights follow a
 *     Gaussian peak centred on the middle of the video:
 *
 *     ```
 *     w_i = 1.0 + 0.5 * exp(-((i - n/2)^2) / (2 * (n/4)^2))
 *     ```
 *
 *     This biases toward the actual content (title cards and fade-to-black
 *     transitions sit at the edges) without zeroing them out entirely.
 *
 * Both platforms use this Gaussian weighting (task brief #7); the iOS
 * `VideoResultAggregator` was ported to match, so a given video produces
 * the same aggregated verdict on iOS and Android.
 */
object VideoResultAggregator {

    private const val HARD_THRESHOLD: Float = 0.9f

    /**
     * Aggregate classifier output across [frames] into a single label list.
     * Returns an empty list when [frames] is empty.
     */
    fun aggregate(frames: List<List<NsfwLabel>>): List<NsfwLabel> {
        if (frames.isEmpty()) return emptyList()

        // Fast path: one frame is clearly positive on an *unsafe* top label.
        // `safe` / `unknown` are excluded — otherwise a single confidently-safe
        // frame would short-circuit the whole video to safe even when later
        // frames are NSFW (false negative). Matches iOS VideoResultAggregator.
        for (frameLabels in frames) {
            val top = frameLabels.maxByOrNull { it.confidence } ?: continue
            if (top.confidence >= HARD_THRESHOLD &&
                top.category != "safe" &&
                top.category != "unknown"
            ) {
                return frameLabels.sortedByDescending { it.confidence }
            }
        }

        val n = frames.size
        val center = n / 2.0
        val sigma = maxOf(1.0, n / 4.0)
        val twoSigmaSq = 2.0 * sigma * sigma

        val weightedSums = HashMap<String, Float>()
        // Per-category weight: a category present in only some frames is
        // normalised against those frames, not the whole video — otherwise a
        // brief detection gets diluted toward zero.
        val weightOfCategory = HashMap<String, Float>()

        for ((i, frameLabels) in frames.withIndex()) {
            val dx = i - center
            val weight = (1.0 + 0.5 * exp(-(dx * dx) / twoSigmaSq)).toFloat()
            for (label in frameLabels) {
                weightedSums[label.category] =
                    (weightedSums[label.category] ?: 0f) + label.confidence * weight
                weightOfCategory[label.category] =
                    (weightOfCategory[label.category] ?: 0f) + weight
            }
        }

        return weightedSums.entries
            .mapNotNull { (cat, sum) ->
                val w = weightOfCategory[cat] ?: 0f
                if (w <= 0f) null else NsfwLabel(cat, sum / w)
            }
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
