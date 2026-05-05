package com.example.nsfw_detect_ios.ml

/**
 * Canonical model identifiers shared between Dart and native layers.
 *
 * IMPORTANT: these strings MUST match the iOS values in
 * `ios/Classes/scanner/ScanConfiguration.swift` (`enum ModelIds`).
 */
object ModelIds {
    const val OPEN_NSFW_2 = "opennsfw2_coreml"
    const val FALCONSAI = "falconsai_nsfw"
    const val ADAMCODD = "adamcodd_nsfw"
}
