import AVFoundation
import CoreVideo
import Foundation

actor CameraVideoRecorder {

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime = .invalid
    private var outputURL: URL?

    private(set) var isRecording = false

    private(set) var triggeringClassification: NsfwClassification?

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

    func append(_ pixelBuffer: CVPixelBuffer) {
        guard isRecording,
              let input = videoInput,
              let pa    = adaptor,
              input.isReadyForMoreMediaData else { return }
        let pts = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()),
                                 sessionStart)
        pa.append(pixelBuffer, withPresentationTime: pts)
    }

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
