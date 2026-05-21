import Foundation
import Photos
import CoreImage
import UIKit
import ImageIO

/// Fetches a PHAsset image and converts it to a CVPixelBuffer for ML inference.
///
/// Two paths:
///  - When given a `PHCachingImageManager`, uses `requestImage(targetSize:contentMode:)`
///    so that prefetched assets actually hit the cache. Options must match the ones
///    passed to `startCachingImages` exactly, or Photos treats the request as a miss.
///  - Otherwise, falls back to `requestImageDataAndOrientation` + ImageIO thumbnailing,
///    which avoids a full-resolution decode for one-shot scans.
final class ImageAnalyzer {

    private let inputSize: Int
    private let targetSize: CGSize
    private let imageManager: PHImageManager

    /// Color space is immutable — share one across the whole process instead of
    /// rebuilding it for every CGContext.
    fileprivate static let sharedDeviceRGB: CGColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Reuses CVPixelBuffer-backed IOSurfaces across frames. Pool is tied to
    /// `inputSize` × `inputSize` × BGRA — built eagerly in `init` so concurrent
    /// callers never race on lazy-var initialisation.
    ///
    /// History: was `lazy var` until 2026-05-05 — `ScanSessionTask` runs
    /// `pixelBuffer(for:)` from inside `withTaskGroup` across N Swift Tasks
    /// sharing one `ImageAnalyzer`; lazy-var initialisation in Swift is NOT
    /// thread-safe and a partial pointer write trashed the pool. Symptom was
    /// `EXC_BAD_ACCESS` inside `CVPixelBufferPool::createPixelBuffer +0x18`
    /// on cooperative-queue threads. Eager init fixes it.
    ///
    /// `nil` if pool creation fails; we then fall back to per-frame
    /// `CVPixelBufferCreate` in `renderToPooledBuffer`.
    private let pixelBufferPool: CVPixelBufferPool?

    init(inputSize: Int = 224, imageManager: PHImageManager = PHImageManager.default()) {
        self.inputSize = inputSize
        self.targetSize = CGSize(width: inputSize, height: inputSize)
        self.imageManager = imageManager
        self.pixelBufferPool = ImageAnalyzer.makePixelBufferPool(inputSize: inputSize)
    }

    private static func makePixelBufferPool(inputSize: Int) -> CVPixelBufferPool? {
        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey:              kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey:                        inputSize,
            kCVPixelBufferHeightKey:                       inputSize,
            kCVPixelBufferIOSurfacePropertiesKey:          [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey:         true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixelBufferAttrs as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }

    private func renderToPooledBuffer(_ cgImage: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        // Fallback to one-shot allocation if the pool is unavailable.
        if buffer == nil {
            return cgImage.toPixelBuffer(size: targetSize)
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data:              CVPixelBufferGetBaseAddress(pixelBuffer),
            width:             inputSize,
            height:            inputSize,
            bitsPerComponent:  8,
            bytesPerRow:       CVPixelBufferGetBytesPerRow(pixelBuffer),
            space:             ImageAnalyzer.sharedDeviceRGB,
            bitmapInfo:        CGBitmapInfo.byteOrder32Little.rawValue |
                               CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: inputSize, height: inputSize))
        return pixelBuffer
    }

    /// Shared request options. Prefetcher and analyzer MUST use identical settings,
    /// otherwise PHCachingImageManager treats the request as a cache miss.
    static func makeRequestOptions() -> PHImageRequestOptions {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false
        opts.deliveryMode = .fastFormat
        opts.resizeMode = .fast
        return opts
    }

    func pixelBuffer(for asset: PHAsset) async throws -> CVPixelBuffer {
        return try await pixelBuffer(for: asset, region: nil)
    }

    /// ROI-aware variant. If `region` is non-nil, the fetched image is
    /// cropped to the normalised rect AFTER initial decode but BEFORE the
    /// final resize-to-input-size. The crop runs on the BGRA pooled buffer
    /// (cheaper than re-rendering from CGImage). Falls back to the
    /// un-cropped buffer if the crop math collapses (e.g. zero-area ROI
    /// after clamping), which is the safer behaviour for inference.
    func pixelBuffer(for asset: PHAsset, region: RoiCropper.Region?) async throws -> CVPixelBuffer {
        let cgImage = try await fetchCGImage(for: asset)
        guard let buffer = renderToPooledBuffer(cgImage) else {
            throw ScanError.frameSamplingFailed
        }
        if let region = region, let cropped = RoiCropper.crop(buffer, region: region) {
            return cropped
        }
        return buffer
    }

    private func fetchCGImage(for asset: PHAsset) async throws -> CGImage {
        // Caching path — only meaningful if imageManager is a PHCachingImageManager
        // that has already started caching this asset at the same targetSize/contentMode/options.
        if imageManager is PHCachingImageManager {
            do {
                return try await fetchViaImageManager(asset: asset)
            } catch let nsErr as NSError where Self.isPHResourceUnavailable(nsErr) {
                // PHCachingImageManager refuses some assets in limited-library
                // / iCloud-only scenarios with PHPhotosError 3303
                // (invalidResource). PHImageManager.default() with explicit
                // requestImageDataAndOrientation often succeeds where the
                // cache path fails — try that as a second-chance.
                NSLog("[NSFW] CachingManager failed (3303), retrying via PHImageManager.default(): %@",
                      asset.localIdentifier)
                return try await fetchViaImageData(asset: asset)
            }
        }
        return try await fetchViaImageData(asset: asset)
    }

    /// `PHPhotosErrorDomain` 3303 = `PHPhotosErrorInvalidResource`.
    /// Apple uses the same code for "asset not in granted limited library",
    /// "iCloud-only and no network", and a handful of cache-edge-cases —
    /// all of which the data-based fetch (PHImageManager.default()) can
    /// usually still recover.
    private static func isPHResourceUnavailable(_ err: NSError) -> Bool {
        return err.domain == "PHPhotosErrorDomain" && err.code == 3303
    }

    private func fetchViaImageManager(asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeOnce: (Result<CGImage, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let img): continuation.resume(returning: img)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }

            let opts = ImageAnalyzer.makeRequestOptions()
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    resumeOnce(.failure(error))
                    return
                }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }
                // We request `.fastFormat`, which is a single-callback mode —
                // there is no "final image" coming after a degraded one. If
                // Photos still flags degraded (rare edge cases on iCloud-only
                // assets), accept it anyway when the image is present;
                // skipping would leak the continuation (H4).
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded && image == nil {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }
                guard let img = image, let cg = img.cgImage else {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }
                resumeOnce(.success(cg))
            }
        }
    }

    private func fetchViaImageData(asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false
            opts.deliveryMode = .fastFormat

            var hasResumed = false
            let resumeOnce: (Result<CGImage, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let img): continuation.resume(returning: img)
                case .failure(let err): continuation.resume(throwing: err)
                }
            }

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: opts
            ) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    resumeOnce(.failure(error))
                    return
                }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }
                guard let data = data else {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }

                // Use ImageIO to create a downscaled thumbnail directly from compressed data.
                // This is MUCH faster than decoding full resolution then scaling.
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }

                let maxPixel = Int(max(self.targetSize.width, self.targetSize.height))
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]

                if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
                    resumeOnce(.success(thumbnail))
                } else if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    resumeOnce(.success(cgImage))
                } else {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                }
            }
        }
    }
}

extension CGImage {
    /// Renders the CGImage into a CVPixelBuffer at the given size.
    /// Uses BGRA pixel format — the native format for Vision/CoreML on iOS.
    func toPixelBuffer(size: CGSize) -> CVPixelBuffer? {
        let width  = Int(size.width)
        let height = Int(size.height)

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey:         true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey:          [:] as [String: Any],
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data:              CVPixelBufferGetBaseAddress(buffer),
            width:             width,
            height:            height,
            bitsPerComponent:  8,
            bytesPerRow:       CVPixelBufferGetBytesPerRow(buffer),
            space:             ImageAnalyzer.sharedDeviceRGB,
            bitmapInfo:        CGBitmapInfo.byteOrder32Little.rawValue |
                               CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.draw(self, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
