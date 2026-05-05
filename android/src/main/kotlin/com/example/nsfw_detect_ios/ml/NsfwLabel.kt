package com.example.nsfw_detect_ios.ml

/**
 * Canonical classification label produced by an [MLEngine].
 *
 * `category` is one of: "safe" | "suggestive" | "nudity" | "explicitNudity" | "unknown".
 */
data class NsfwLabel(val category: String, val confidence: Float)
