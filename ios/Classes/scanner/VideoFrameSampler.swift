import Foundation
import Photos
import AVFoundation
import CoreVideo

/// Extracts representative frames from a video PHAsset using uniform temporal sampling.
final class VideoFrameSampler {

    /// Hamming-distance threshold for perceptual dedupe. Frames whose
    /// 8×8 dHash differs from the last accepted frame by ≤ this many bits
    /// are skipped before they hit the inference pipeline. 6 was tuned
    /// empirically against keyframe bursts; raise to be more aggressive,
    /// lower to keep more frames.
    static let perceptualDedupeHammingThreshold = 6

    /// When true, the sampler skips frames whose 8×8 dHash is within
    /// `perceptualDedupeHammingThreshold` bits of the previous accepted
    /// frame. Disable for tests that intentionally feed repeated content.
    var enablePerceptualDedupe: Bool

    /// Optional ROI applied to each frame BEFORE the dedupe/return step,
    /// so the dedupe hash and the downstream model both see the same
    /// cropped pixels.
    var region: RoiCropper.Region?

    init(enablePerceptualDedupe: Bool = true, region: RoiCropper.Region? = nil) {
        self.enablePerceptualDedupe = enablePerceptualDedupe
        self.region = region
    }

    func sample(asset: PHAsset, config: ScanConfiguration, inputSize: Int = 224) async throws -> [CVPixelBuffer] {
        let avAsset = try await loadAVAsset(for: asset)
        let duration = avAsset.duration.seconds
        guard duration > 0 else { return [] }

        let times = computeSampleTimes(duration: duration, config: config)
        guard !times.isEmpty else { return [] }

        return try await extractFrames(from: avAsset, at: times, inputSize: inputSize)
    }

    // MARK: - Private

    private func loadAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let opts = PHVideoRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.isNetworkAccessAllowed = true

            var hasResumed = false
            let resumeOnce: (Result<AVAsset, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let a): continuation.resume(returning: a)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: opts
            ) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let avAsset = avAsset else {
                    resumeOnce(.failure(ScanError.frameSamplingFailed))
                    return
                }
                resumeOnce(.success(avAsset))
            }
        }
    }

    private func computeSampleTimes(duration: Double, config: ScanConfiguration) -> [NSValue] {
        if duration <= 3.0 {
            // Short clip: sample every 0.5 s
            var times: [NSValue] = []
            var t = 0.5
            while t < duration {
                times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
                t += 0.5
            }
            return Array(times.prefix(config.maxVideoFrames))
        }

        let interval = max(config.videoFrameInterval, duration / Double(config.maxVideoFrames + 1))
        var sampleTimes: [Double] = [min(1.0, duration * 0.05)] // near start, not a black frame

        var t = interval
        while t < duration - 1.0 && sampleTimes.count < config.maxVideoFrames - 1 {
            sampleTimes.append(t)
            t += interval
        }

        // Always include a frame near the end
        if duration > 2.0 {
            sampleTimes.append(duration - min(1.5, duration * 0.1))
        }

        // Deduplicate and sort
        let unique = Array(Set(sampleTimes.map { ($0 * 10).rounded() / 10 })).sorted()
        return Array(unique.prefix(config.maxVideoFrames)).map {
            NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
        }
    }

    private func extractFrames(from avAsset: AVAsset, at times: [NSValue], inputSize: Int) async throws -> [CVPixelBuffer] {
        // generateCGImagesAsynchronously never invokes the callback for an
        // empty input — would leak the continuation (H5). The public
        // `sample(asset:)` already guards this, but `extractFrames` is
        // module-internal and the contract belongs here too.
        guard !times.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        let targetSize = CGSize(width: inputSize, height: inputSize)
        generator.maximumSize = targetSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Capture instance state into locals — the generator closure can be
        // called from any thread; we don't want any racy `self.` reads.
        let dedupeEnabled = enablePerceptualDedupe
        let region        = self.region
        let dedupeThreshold = Self.perceptualDedupeHammingThreshold

        return try await withCheckedThrowingContinuation { continuation in
            // Synchronized access — the callback fires on an arbitrary serial queue,
            // but multiple invocations can overlap if the generator uses >1 thread.
            let lock = NSLock()
            var buffers:   [CVPixelBuffer] = []
            var completed  = 0
            var failed     = 0
            var skippedAsDuplicate = 0
            var lastHash:  UInt64? = nil
            var hasResumed = false
            let total      = times.count

            generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, error in
                lock.lock()
                defer { lock.unlock() }

                switch result {
                case .succeeded:
                    if let img = cgImage, var buffer = img.toPixelBuffer(size: targetSize) {
                        // ROI crop (before dedupe so the hash reflects the
                        // pixels the model will actually see).
                        if let region = region,
                           let cropped = RoiCropper.crop(buffer, region: region) {
                            buffer = cropped
                        }
                        // Perceptual dedupe — drop near-duplicate frames.
                        if dedupeEnabled, let hash = PerceptualHash.dHash(buffer) {
                            if let prev = lastHash,
                               PerceptualHash.hammingDistance(prev, hash) <= dedupeThreshold {
                                skippedAsDuplicate += 1
                            } else {
                                lastHash = hash
                                buffers.append(buffer)
                            }
                        } else {
                            buffers.append(buffer)
                        }
                    } else {
                        failed += 1
                    }
                case .failed:
                    failed += 1
                    if let e = error {
                        NSLog("[NSFW] VideoFrameSampler: frame failed: %@", e.localizedDescription)
                    }
                case .cancelled:
                    failed += 1
                @unknown default:
                    failed += 1
                }

                completed += 1
                if completed == total && !hasResumed {
                    hasResumed = true
                    if buffers.isEmpty && failed == total {
                        NSLog("[NSFW] VideoFrameSampler: all %d frames failed", total)
                    }
                    if skippedAsDuplicate > 0 {
                        NSLog("[NSFW] VideoFrameSampler: dedupe skipped %d/%d frames",
                              skippedAsDuplicate, total)
                    }
                    continuation.resume(returning: buffers)
                }
            }
        }
    }
}
