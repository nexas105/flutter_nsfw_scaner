import AVFoundation
import CoreVideo
import Foundation

/// Records raw camera frames to a temporary MP4 clip once NSFW content is
/// detected. Started lazily on the first NSFW hit via `startIfNeeded`; every
/// subsequent frame is appended via `append`; finalized in `finish` when the
/// session stops. Thread-safe via actor isolation.
actor CameraVideoRecorder {

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime = .invalid
    private var outputURL: URL?

    private(set) var isRecording = false

    /// The classification that triggered recording — stored so the caller can
    /// pass it to the upload queue without keeping a separate reference.
    private(set) var triggeringClassification: NsfwClassification?

    // MARK: - Public API

    /// Start recording using `source` to derive frame dimensions. No-op if
    /// already recording. Returns immediately — first `append` call opens the
    /// AVAssetWriter session.
    func startIfNeeded(source: CVPixelBuffer,
                       classification: NsfwClassification) {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            NSLog("[NSFW] CameraVideoRecorder: AVAssetWriter init failed")
            return
        }

        let width  = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let pa = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil)

        guard w.canAdd(input) else {
            NSLog("[NSFW] CameraVideoRecorder: cannot add video input")
            return
        }
        w.add(input)
        w.startWriting()

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        w.startSession(atSourceTime: now)

        writer     = w
        videoInput = input
        adaptor    = pa
        sessionStart = now
        outputURL  = url
        isRecording = true
        triggeringClassification = classification

        NSLog("[NSFW] CameraVideoRecorder: started recording → %@", url.lastPathComponent)
    }

    /// Append a camera frame. No-op if not recording or input not ready.
    func append(_ pixelBuffer: CVPixelBuffer) {
        guard isRecording,
              let input = videoInput,
              let pa    = adaptor,
              input.isReadyForMoreMediaData else { return }
        let pts = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()),
                                 sessionStart)
        pa.append(pixelBuffer, withPresentationTime: pts)
    }

    /// Finalize the clip. Returns the output URL on success, nil otherwise.
    /// Cleans up the temp file automatically on failure.
    func finish() async -> URL? {
        guard isRecording, let w = writer, let input = videoInput else { return nil }
        isRecording = false
        input.markAsFinished()
        await w.finishWriting()

        if w.status == .completed, let url = outputURL {
            NSLog("[NSFW] CameraVideoRecorder: finished → %@ (%.1f MB)",
                  url.lastPathComponent,
                  Double((try? FileManager.default
                      .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) ?? 0)
                  / 1_048_576)
            return url
        }
        NSLog("[NSFW] CameraVideoRecorder: finishWriting failed — %@",
              w.error?.localizedDescription ?? "unknown")
        outputURL.flatMap { try? FileManager.default.removeItem(at: $0) }
        return nil
    }
}
