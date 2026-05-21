// PerceptualHash.swift
//
// Cheap 8×8 dHash for CVPixelBuffer-backed frames. Used by
// `VideoFrameSampler` to skip near-duplicate sampled frames before they
// hit the inference pipeline. ~30–50% inference savings on keyframe
// bursts (long static intros, slideshow-style clips, repeated logos).
//
// Algorithm — classic "difference hash":
//   1. Downsample the source frame to a 9×8 grayscale grid.
//   2. For each row, build 8 bits by comparing adjacent columns
//      (`bit_i = (col_i+1 > col_i) ? 1 : 0`).
//   3. Concatenate the 8 rows into a single 64-bit value.
//
// Hamming distance between two hashes ≈ perceptual similarity.
// Distance ≤ 6 (out of 64) is empirically near-identical content for
// dHash on 224–384 input frames.
//
// Implementation notes:
//   • We render through CoreImage to a tiny BGRA CVPixelBuffer, then read
//     the byte buffer directly. We deliberately do NOT pull in vImage just
//     for this — CoreImage is already linked.
//   • Greyscale is approximated as (R + G + B) / 3 — cheap, good-enough
//     signal for difference-hashing.

import Foundation
import CoreImage
import CoreVideo

enum PerceptualHash {

    /// dHash width (= 9 because we need N+1 columns to produce N bits).
    private static let hashSampleW = 9
    private static let hashSampleH = 8

    /// Shared CIContext — allocation is expensive, the bytes-readback path
    /// doesn't benefit from caching intermediates.
    private static let ciContext: CIContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])

    /// Hamming distance between two 64-bit hashes (0…64).
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    /// Compute a 64-bit dHash for a CVPixelBuffer. Returns `nil` if the
    /// downsample / readback fails — callers should treat that as
    /// "can't dedupe this frame, accept it" rather than skipping.
    static func dHash(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        // Build a 9×8 BGRA output buffer.
        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey:               hashSampleW,
            kCVPixelBufferHeightKey:              hashSampleH,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            hashSampleW, hashSampleH,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let dstBuffer = dst else { return nil }

        // Scale source to 9×8 ignoring aspect ratio — dHash is robust to
        // light distortion, and matching aspect would require a crop that
        // changes content in a way that defeats the dedupe.
        let scaleX = CGFloat(hashSampleW) / CGFloat(srcW)
        let scaleY = CGFloat(hashSampleH) / CGFloat(srcH)
        let scaled = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        ciContext.render(scaled, to: dstBuffer)

        // Read back BGRA bytes from the small buffer.
        CVPixelBufferLockBaseAddress(dstBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(dstBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(dstBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Per-row greyscale array (length hashSampleW). Then per-row,
        // compare adjacent columns to produce hashSampleH * (hashSampleW - 1)
        // = 8 * 8 = 64 bits.
        var hash: UInt64 = 0
        var bitIndex = 63
        for y in 0..<hashSampleH {
            // Compute the 9 greyscale values for this row.
            var row: [Int] = Array(repeating: 0, count: hashSampleW)
            let rowBase = ptr.advanced(by: y * bytesPerRow)
            for x in 0..<hashSampleW {
                let px = rowBase.advanced(by: x * 4)
                // BGRA: index 0=B, 1=G, 2=R, 3=A
                let b = Int(px[0])
                let g = Int(px[1])
                let r = Int(px[2])
                row[x] = (r + g + b) / 3
            }
            // 8 bit comparisons per row.
            for x in 0..<(hashSampleW - 1) {
                if row[x + 1] > row[x] {
                    hash |= (UInt64(1) << bitIndex)
                }
                bitIndex -= 1
            }
        }
        return hash
    }
}
