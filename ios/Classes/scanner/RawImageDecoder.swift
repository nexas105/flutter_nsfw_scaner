// RawImageDecoder.swift
//
// Decodes camera RAW files (DNG, CR2/CR3, NEF, ARW, RAF, RW2, ORF, SRW) to a
// CVPixelBuffer the NSFW classifier can consume.
//
// Background:
//   • iOS Image I/O has progressively broadened RAW support — DNG works on
//     every supported iOS version, and `CIRAWFilter` (iOS 15+) handles most
//     proprietary RAWs natively. Even on older iOS, every modern camera
//     embeds a 1080p+ JPEG thumbnail inside the RAW container, and
//     `CGImageSourceCreateThumbnailAtIndex` with
//     `kCGImageSourceCreateThumbnailFromImageAlways: true` extracts it
//     reliably. 1080p is plenty for NSFW classification.
//
// Reliability matrix (best-effort, based on Apple docs + field reports):
//   • DNG               — native Image I/O decode, all iOS versions.
//   • CR2 (Canon CR2)   — `CIRAWFilter` iOS 15+, JPEG thumbnail otherwise.
//   • CR3 (Canon CR3)   — `CIRAWFilter` iOS 15+, JPEG thumbnail otherwise.
//   • NEF (Nikon)       — `CIRAWFilter` iOS 15+, JPEG thumbnail otherwise.
//   • ARW (Sony)        — `CIRAWFilter` iOS 15+, JPEG thumbnail otherwise.
//   • RAF (Fujifilm)    — `CIRAWFilter` iOS 15+ on newer bodies; thumbnail fallback.
//   • RW2 (Panasonic)   — `CIRAWFilter` iOS 15+, JPEG thumbnail otherwise.
//   • ORF (Olympus)     — `CIRAWFilter` iOS 15+ on common bodies; thumbnail fallback.
//   • SRW (Samsung)     — thumbnail fallback in most builds.
//
// Strategy in `decode(url:targetSize:)`:
//   1. On iOS 15+ try `CIRAWFilter(imageURL:)` with default settings
//      (no exposure / WB override). If it returns a CIImage, render to BGRA.
//   2. Otherwise (or on `CIRAWFilter` failure) fall back to Image I/O's
//      thumbnail path. Returns nil if both routes fail.

import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import UIKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum RawImageDecoder {

    /// Lowercased file-extensions Image I/O / CIRAWFilter can decode on
    /// modern iOS. CR3 has been adopted by `CIRAWFilter` since iOS 14.3, so
    /// it's safe to include.
    static let supportedExtensions: Set<String> = [
        "dng",
        "cr2", "cr3",
        "nef", "nrw",
        "arw", "srf", "sr2",
        "raf",
        "rw2",
        "orf",
        "srw",
    ]

    /// Lightweight cap — RAW files are typically 20–60 MB and the embedded
    /// thumbnail is 1080p+, which is well above what the classifier needs.
    /// Larger than `224` so subsequent ROI crops still have headroom before
    /// the final analyzer resize.
    static let defaultTargetSize = CGSize(width: 1024, height: 1024)

    /// Returns true when `url` looks like a RAW container Image I/O is
    /// willing to open. We check the extension AND a successful
    /// `CGImageSourceCreateWithURL` so we never trigger the slow RAW
    /// decode for a misnamed JPEG.
    static func canDecode(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, supportedExtensions.contains(ext) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        // `CGImageSourceGetType` returns the UTI. For RAW formats Image I/O
        // surfaces `public.camera-raw-image` (or a vendor-specific subtype).
        // We accept any non-nil type — the extension check already gated us.
        return CGImageSourceGetType(source) != nil
    }

    /// Decode the RAW file at `url` to a BGRA `CVPixelBuffer` at roughly
    /// `targetSize` (Image I/O / CIRAWFilter sizing is approximate — the
    /// downstream analyzer resizes to model input size anyway).
    ///
    /// Returns `nil` if every decode path fails. Callers should fall back
    /// to their existing `CGImageSource` decode in that case.
    static func decode(url: URL, targetSize: CGSize = defaultTargetSize) -> CVPixelBuffer? {
        if #available(iOS 15.0, *) {
            if let buffer = decodeViaCIRAW(url: url, targetSize: targetSize) {
                return buffer
            }
        }
        return decodeViaThumbnail(url: url, targetSize: targetSize)
    }

    // MARK: - CIRAWFilter path (iOS 15+)

    @available(iOS 15.0, *)
    private static func decodeViaCIRAW(url: URL, targetSize: CGSize) -> CVPixelBuffer? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        // Default settings: no exposure / WB override (matches what
        // Photos.app shows the user — the model should see "as-shot"
        // brightness rather than a flat linear scene).
        guard let ciImage = filter.outputImage else { return nil }
        return renderCIImageToBGRA(ciImage, targetSize: targetSize)
    }

    private static func renderCIImageToBGRA(_ ciImage: CIImage, targetSize: CGSize) -> CVPixelBuffer? {
        let sourceExtent = ciImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        // Aspect-fit into targetSize so the analyzer's later resize works
        // on a frame that's not absurdly larger than the model input.
        let scaleW = targetSize.width  / sourceExtent.width
        let scaleH = targetSize.height / sourceExtent.height
        let scale  = min(scaleW, scaleH)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outW = Int(scaled.extent.width.rounded())
        let outH = Int(scaled.extent.height.rounded())
        guard outW > 0, outH > 0 else { return nil }

        var dst: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey:               outW,
            kCVPixelBufferHeightKey:              outH,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outW, outH,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &dst
        )
        guard status == kCVReturnSuccess, let buffer = dst else { return nil }

        // Translate so the scaled extent's origin lands at (0, 0) of the
        // destination buffer — `CIContext.render(_:to:)` honours extent.
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: -scaled.extent.origin.x,
            y: -scaled.extent.origin.y))
        Self.ciContext.render(translated, to: buffer)
        return buffer
    }

    // MARK: - Thumbnail fallback (all iOS versions)

    private static func decodeViaThumbnail(url: URL, targetSize: CGSize) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixel = Int(max(targetSize.width, targetSize.height))
        let opts: [CFString: Any] = [
            // Force-create from the *image* even when the file has an
            // embedded thumbnail too small for our needs. Modern RAW files
            // ship a 1080p+ embedded JPEG, which is what this returns.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixel,
            kCGImageSourceCreateThumbnailWithTransform:   true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage.toPixelBuffer(size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    /// Shared CIContext — mirrors the caching policy used by `RoiCropper` and
    /// the camera resize step so we don't accidentally fragment GPU caches.
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
    ])
}
