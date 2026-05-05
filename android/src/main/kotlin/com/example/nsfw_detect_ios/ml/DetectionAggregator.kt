package com.example.nsfw_detect_ios.ml

/**
 * Shared helper: collapse a per-frame [BodyPartDetection] list into the
 * `[{category, confidence}, ...]` label list that `ScanResult` and
 * `CameraFrameResult` carry on the wire. Mirrors iOS' equivalent
 * `NsfwClassification.fromDetections(...)` aggregation.
 *
 * Behaviour (must match the previous inline block in
 * [com.example.nsfw_detect_ios.ScanSessionTask.runDetectionScan] byte-for-byte
 * — extracted here so the camera pipeline doesn't carry a second copy):
 *
 *  1. Per-aggregated-category, take the **max** confidence across all
 *     surviving detections.
 *  2. **NSFW boost.** Any `*_EXPOSED` detection that survived NudeNet's
 *     IoU + detection-confidence threshold is treated as authoritative —
 *     its aggregated category's confidence is bumped to **1.0** so
 *     `isNsfw`, the gallery filter, and the upload trigger all fire
 *     reliably. Per-box scores in the original detections list are
 *     unaffected.
 *  3. Final sort: NSFW priority bucket first, confidence second.
 *
 *     Priority: `explicitNudity` < `nudity` < `suggestive` < `safe` <
 *     `unknown`. (Lower rank = sorts first.)
 *
 * The output is a list of `Map<String, Any>` with stable keys
 * `category` (String) and `confidence` (Double), exactly as the
 * EventChannel labels payload expects.
 */
object DetectionAggregator {
    private val CATEGORY_RANK = mapOf(
        "explicitNudity" to 0,
        "nudity" to 1,
        "suggestive" to 2,
        "safe" to 3,
        "unknown" to 4,
    )

    fun aggregate(detections: List<BodyPartDetection>): List<Map<String, Any>> {
        val perCat = HashMap<String, Float>()
        for (d in detections) {
            val prev = perCat[d.aggregatedCategory] ?: 0f
            if (d.confidence > prev) perCat[d.aggregatedCategory] = d.confidence
        }
        // NSFW boost: any surviving *_EXPOSED hit (genitalia, anus, breast,
        // buttocks → bucketed into nudity / explicitNudity by
        // BodyPartDetection.aggregateCategoryFor) counts as authoritative.
        if (perCat.containsKey("explicitNudity")) perCat["explicitNudity"] = 1f
        if (perCat.containsKey("nudity")) perCat["nudity"] = 1f
        return perCat
            .entries
            .sortedWith(
                compareBy<Map.Entry<String, Float>> {
                    CATEGORY_RANK[it.key] ?: Int.MAX_VALUE
                }.thenByDescending { it.value }
            )
            .map { mapOf("category" to it.key, "confidence" to it.value.toDouble()) }
    }
}
