import Foundation
import Photos
import AVFoundation
import CoreVideo

/// Extracts representative frames from a video PHAsset using uniform temporal sampling.
final class VideoFrameSampler {

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
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        let targetSize = CGSize(width: inputSize, height: inputSize)
        generator.maximumSize = targetSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 0.5, preferredTimescale: 600)

        return try await withCheckedThrowingContinuation { continuation in
            // Synchronized access — the callback fires on an arbitrary serial queue,
            // but multiple invocations can overlap if the generator uses >1 thread.
            let lock = NSLock()
            var buffers:   [CVPixelBuffer] = []
            var completed  = 0
            var hasResumed = false
            let total      = times.count

            generator.generateCGImagesAsynchronously(forTimes: times) { _, cgImage, _, result, error in
                lock.lock()
                defer { lock.unlock() }

                if result == .succeeded, let img = cgImage,
                   let buffer = img.toPixelBuffer(size: targetSize) {
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
