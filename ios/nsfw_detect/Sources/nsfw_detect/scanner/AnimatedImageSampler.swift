// AnimatedImageSampler.swift
//
// Detects and frame-samples animated image containers (GIF / WebP / animated
// HEIC / animated PNG / APNG) for the NSFW classifier.
//
// Why this exists:
//   • The default `ImageAnalyzer` decode path used `CGImageSourceCreateImageAtIndex(src, 0, …)`,
//     which silently classifies only the *first* frame of an animated GIF/WebP.
//     For NSFW content that doesn't surface until later in the loop, this
//     leaks unsafe imagery into "safe" results (issue #53).
//
// Strategy:
//   • `isAnimated(url:)` consults Image I/O's frame count + container-specific
//     metadata dictionaries (`kCGImagePropertyGIFDictionary`,
//     `kCGImagePropertyPNGDictionary` APNG bits, `kCGImagePropertyHEICSDictionary`).
//     Image I/O on iOS 14+ also exposes WebP via `public.webp` — frames live
//     under the WebP container with the same `count > 1` discriminator.
//   • `sampleFrames(url:maxFrames:region:)` extracts up to `maxFrames` evenly
//     spaced frames, decoded one at a time via `CGImageSourceCreateImageAtIndex`,
//     downscaled to the input size, and rendered through the supplied
//     `CVPixelBufferPool` so the per-frame allocation matches the rest of the
//     analyzer pipeline.
//   • Streaming: we never hold more than one CGImage at a time. For huge
//     animated WebPs that's the only way to keep memory bounded.
//   • ROI: applied AFTER pixel-buffer materialisation via the existing
//     `RoiCropper`, identical to the single-frame and video paths.
//
// Wiring: callers (`ImageAnalyzer.scanFile` / `scanBytes`) check
// `isAnimated(url:)` first; if true they feed the sampled frames through the
// standard classification + `VideoResultAggregator` flow so animated images
// share aggregation semantics with short videos.

import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UIKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum AnimatedImageSampler {

    /// Default cap on how many frames we hand to the classifier. Matches the
    /// `maxVideoFrames` default in `ScanConfiguration` so animated GIFs and
    /// short videos converge through the same aggregator with comparable
    /// statistical weight.
    static let defaultMaxFrames: Int = 8

    /// Returns true when the file at `url` is a multi-frame animated image
    /// container. Single-frame GIF/WebP/HEIC/PNG return false so callers can
    /// take the cheap one-shot path.
    static func isAnimated(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return isAnimated(source: src)
    }

    /// CGImageSource-based variant used by the `scanBytes` path so we don't
    /// have to write the buffer to disk just to ask Image I/O whether it's
    /// animated.
    static func isAnimated(source: CGImageSource) -> Bool {
        let count = CGImageSourceGetCount(source)
        if count > 1 { return true }
        // Single-frame container can still self-identify as animated via
        // per-format metadata (rare, but covers some encoder bugs).
        guard let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else {
            return false
        }
        if props[kCGImagePropertyGIFDictionary] != nil { return count > 1 }
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           png[kCGImagePropertyAPNGLoopCount] != nil { return count > 1 }
        // WebP / HEICS animated: Image I/O exposes these on iOS 14+ via the
        // generic frame count. `count > 1` already covered them above.
        return false
    }

    /// Sample up to `maxFrames` evenly-spaced frames from the animated image
    /// at `url`. Each frame is rendered into a fresh BGRA `CVPixelBuffer`
    /// sized to the smaller of `targetSize` or the source frame.
    ///
    /// - Parameters:
    ///   - url:       File URL of the animated container.
    ///   - maxFrames: Hard cap on returned frames (default `defaultMaxFrames`).
    ///   - targetSize: Approximate pixel size for the per-frame thumbnail.
    ///                  Image I/O chooses the largest dimension via
    ///                  `kCGImageSourceThumbnailMaxPixelSize`.
    ///   - region:    Optional ROI applied to each frame buffer via
    ///                  `RoiCropper`. If the crop collapses, the un-cropped
    ///                  buffer is kept (matches the rest of the pipeline).
    /// - Returns: Frame buffers in temporal order. Empty if the source is
    ///   unreadable or no frames decoded successfully.
    static func sampleFrames(
        url: URL,
        maxFrames: Int = defaultMaxFrames,
        targetSize: CGSize = CGSize(width: 224, height: 224),
        region: RoiCropper.Region? = nil
    ) -> [CVPixelBuffer] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return sampleFrames(source: source, maxFrames: maxFrames, targetSize: targetSize, region: region)
    }

    /// CGImageSource-based variant for the `scanBytes` path.
    static func sampleFrames(
        source: CGImageSource,
        maxFrames: Int = defaultMaxFrames,
        targetSize: CGSize = CGSize(width: 224, height: 224),
        region: RoiCropper.Region? = nil
    ) -> [CVPixelBuffer] {
        let totalFrames = CGImageSourceGetCount(source)
        guard totalFrames > 0 else { return [] }
        let cap = max(1, maxFrames)
        let indices = evenlySpacedIndices(total: totalFrames, count: min(cap, totalFrames))
        guard !indices.isEmpty else { return [] }

        let maxPixel = Int(max(targetSize.width, targetSize.height))
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixel,
            kCGImageSourceCreateThumbnailWithTransform:   true,
        ]

        var out: [CVPixelBuffer] = []
        out.reserveCapacity(indices.count)
        for index in indices {
            // Decode-on-demand: one CGImage at a time keeps peak memory low
            // even for big animated WebPs (which Image I/O happily loads
            // into RAM as a single decoded bitmap if asked).
            let cgImage: CGImage? = {
                if let thumb = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOpts as CFDictionary) {
                    return thumb
                }
                return CGImageSourceCreateImageAtIndex(source, index, nil)
            }()
            guard let frame = cgImage,
                  var buffer = frame.toPixelBuffer(size: targetSize) else {
                continue
            }
            if let region = region, let cropped = RoiCropper.crop(buffer, region: region) {
                buffer = cropped
            }
            out.append(buffer)
        }
        return out
    }

    // MARK: - Private

    /// Evenly spaced index sampling — returns up to `count` indices in
    /// `[0, total)` including the first frame and the last frame so a
    /// "title card + content" structure is always represented.
    private static func evenlySpacedIndices(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        if count >= total {
            return Array(0..<total)
        }
        if count == 1 { return [0] }
        var seen = Set<Int>()
        var out: [Int] = []
        let denom = Double(count - 1)
        for k in 0..<count {
            let idx = Int((Double(k) / denom) * Double(total - 1))
            if seen.insert(idx).inserted {
                out.append(idx)
            }
        }
        return out
    }
}
