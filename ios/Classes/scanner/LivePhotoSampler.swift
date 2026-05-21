// LivePhotoSampler.swift
//
// Materialises the paired video that accompanies an iOS Live Photo so the
// NSFW pipeline can sample it the same way it samples any other AVAsset.
//
// Why this exists:
//   • Live Photos look like still images to most APIs but include a
//     ~1.5–3 s companion video. A still that's safe in the keyframe may
//     contain nudity in the paired motion (issue #56). To catch that we
//     need to feed the motion clip through the existing
//     `VideoFrameSampler`.
//
// Strategy:
//   1. Look up the paired-video `PHAssetResource` (`.pairedVideo`).
//   2. Stream the resource bytes to a temp `.mov` so we can hand the URL
//      to `AVURLAsset` and reuse the existing `VideoFrameSampler` /
//      `AVAssetImageGenerator` path — no duplicated decode logic.
//   3. Delete the temp file when the caller is done.
//
// Design notes:
//   • `PHAssetResourceManager.requestData(for:options:dataReceivedHandler:completionHandler:)`
//     streams the resource in chunks so we don't have to load the whole
//     paired video into memory. We append chunks to the temp file via
//     `FileHandle`.
//   • The companion video is short, so we cap samples at ~3 frames in the
//     wiring layer (`ScanMethodHandler.scanSingleAsset`) — this file is
//     purely about materialising the bytes.
//   • Errors fall back to "no video sampled, return the still result"
//     in the caller; we never crash a Live Photo scan just because the
//     paired video resource couldn't be resolved.

import Foundation
import Photos
import AVFoundation

enum LivePhotoSampler {

    /// A handle to a materialised Live-Photo paired video. The caller MUST
    /// call `cleanup()` (or let ARC reclaim the value) when finished — the
    /// temp file persists otherwise.
    final class PairedVideo {
        let url: URL
        private var didCleanup = false
        init(url: URL) { self.url = url }
        deinit { cleanup() }

        func cleanup() {
            if didCleanup { return }
            didCleanup = true
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum SamplerError: Error {
        case pairedVideoResourceMissing
        case fileWriteFailed
        case resourceFetchFailed(Error)
    }

    /// Returns true when `asset` is a Live Photo with an attached
    /// paired-video resource that we can sample. A "still-only Live Photo"
    /// (rare, but possible if the user trimmed the motion) returns false so
    /// callers take the still-only path.
    static func hasPairedVideo(asset: PHAsset) -> Bool {
        guard asset.mediaSubtypes.contains(.photoLive) else { return false }
        return PHAssetResource.assetResources(for: asset)
            .contains(where: { $0.type == .pairedVideo })
    }

    /// Materialise the paired video for `asset` into a temporary `.mov` file
    /// and return its URL inside a `PairedVideo` lifetime handle.
    ///
    /// Caller is responsible for calling `.cleanup()` (or releasing the
    /// returned object) once the AVAsset / frame sampler is done with the
    /// file. Concurrent calls on the same asset produce independent temp
    /// files — no shared cache (the bytes are small and `PHAssetResource`
    /// streams from disk, so there's no benefit to caching).
    static func materialisePairedVideo(asset: PHAsset) async throws -> PairedVideo {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            throw SamplerError.pairedVideoResourceMissing
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("livephoto_\(UUID().uuidString).mov")

        // Create the empty file so FileHandle can attach.
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: tmpURL) else {
            throw SamplerError.fileWriteFailed
        }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var hasResumed = false
                let resumeOnce: (Result<Void, Error>) -> Void = { result in
                    guard !hasResumed else { return }
                    hasResumed = true
                    switch result {
                    case .success:        cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }

                PHAssetResourceManager.default().requestData(
                    for: videoResource,
                    options: opts,
                    dataReceivedHandler: { chunk in
                        // FileHandle.write is synchronous; chunk sizes are
                        // small (Photos streams in ~64 KB increments).
                        handle.write(chunk)
                    },
                    completionHandler: { error in
                        try? handle.close()
                        if let error = error {
                            resumeOnce(.failure(SamplerError.resourceFetchFailed(error)))
                        } else {
                            resumeOnce(.success(()))
                        }
                    }
                )
            }
        } catch {
            // Best-effort cleanup so we don't leak temp files on the
            // failure path. The `PairedVideo` deinit handles success path.
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        return PairedVideo(url: tmpURL)
    }

    /// Convenience: materialise + frame-sample in one call. The temp file is
    /// cleaned up before this function returns — the returned pixel buffers
    /// are independent of the source.
    ///
    /// - Parameters:
    ///   - asset:     The Live Photo PHAsset.
    ///   - maxFrames: Hard cap on returned frames (default 3 — the paired
    ///                video is only ~1.5–3 s so dense sampling wastes time).
    ///   - inputSize: Pixel buffer dimension fed to the model (default 224).
    ///   - region:    Optional ROI applied per frame.
    static func sampleFrames(
        asset: PHAsset,
        maxFrames: Int = 3,
        inputSize: Int = 224,
        region: RoiCropper.Region? = nil
    ) async throws -> [CVPixelBuffer] {
        let paired = try await materialisePairedVideo(asset: asset)
        defer { paired.cleanup() }

        let avAsset = AVURLAsset(url: paired.url)
        // iOS 16: sync `.duration` accessor is deprecated; use async load.
        let duration = try await avAsset.load(.duration).seconds
        guard duration > 0 else { return [] }

        let times = computeSampleTimes(duration: duration, maxFrames: maxFrames)
        guard !times.isEmpty else { return [] }

        return try await extractFrames(
            from: avAsset,
            at: times,
            inputSize: inputSize,
            region: region
        )
    }

    // MARK: - Private

    /// Live-photo paired videos are tiny; uniform spacing without the
    /// "near start / near end" heuristics of `VideoFrameSampler` is fine.
    private static func computeSampleTimes(duration: Double, maxFrames: Int) -> [NSValue] {
        let count = max(1, min(maxFrames, 8))
        if count == 1 {
            return [NSValue(time: CMTime(seconds: duration * 0.5, preferredTimescale: 600))]
        }
        var out: [NSValue] = []
        let denom = Double(count - 1)
        for k in 0..<count {
            // Pad the ends slightly so we don't catch the LP "stop frame"
            // (last frame is often identical to the still).
            let t = max(0.05, min(duration - 0.05,
                                  (Double(k) / denom) * duration))
            out.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
        }
        return out
    }

    /// Mirror of `VideoFrameSampler.extractFrames` but without the
    /// perceptual-dedupe pass — paired videos are too short for dedupe to
    /// pay off, and the aggregator is happy with 3 raw frames.
    private static func extractFrames(
        from avAsset: AVAsset,
        at times: [NSValue],
        inputSize: Int,
        region: RoiCropper.Region?
    ) async throws -> [CVPixelBuffer] {
        guard !times.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        let targetSize = CGSize(width: inputSize, height: inputSize)
        generator.maximumSize = targetSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.2, preferredTimescale: 600)

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var buffers: [CVPixelBuffer] = []
            var completed = 0
            var hasResumed = false
            let total = times.count

            generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, _ in
                lock.lock()
                defer { lock.unlock() }
                if result == .succeeded,
                   let img = cgImage,
                   var buffer = img.toPixelBuffer(size: targetSize) {
                    if let region = region,
                       let cropped = RoiCropper.crop(buffer, region: region) {
                        buffer = cropped
                    }
                    buffers.append(buffer)
                }
                completed += 1
                if completed == total && !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: buffers)
                }
            }
        }
    }
}
