import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Detection-aware media redaction. Applies blur / pixelate / blackBox to
/// either the per-detection bounding boxes (when present) or the whole image
/// (classifier-only fallback). Pendant to
/// `android/.../redaction/MediaRedactor.kt`.
enum MediaRedactor {

    enum Mode: String {
        case blur
        case pixelate
        case blackBox
    }

    /// Normalised [0, 1] coords with top-left origin (matches what Vision
    /// detection emits and the Dart wire shape).
    struct Box {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    enum Error: Swift.Error, LocalizedError {
        case decodeFailed
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "Could not decode image bytes for redaction"
            case .encodeFailed: return "Could not encode redacted image"
            }
        }
    }

    /// Re-used CIContext — building a fresh context per call allocates Metal
    /// state, which is expensive when redaction runs in tight loops.
    private static let sharedContext = CIContext()

    static func redact(
        data: Data,
        boxes: [Box],
        mode: Mode,
        intensity: Double,
        outputFormat: String
    ) throws -> Data {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            throw Error.decodeFailed
        }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let ciImage = CIImage(cgImage: cgImage)
        let clamped = max(0.0, min(1.0, intensity))

        // Map normalised top-left boxes into CIImage's bottom-left coordinate
        // space. Detection-mode emits per-box rects; classifier-only scans
        // (no detections) fall back to redacting the full frame.
        let pixelRects: [CGRect]
        if boxes.isEmpty {
            pixelRects = [CGRect(origin: .zero, size: imageSize)]
        } else {
            pixelRects = boxes.map { box in
                let x = box.x * imageSize.width
                let y = imageSize.height - (box.y + box.height) * imageSize.height
                return CGRect(
                    x: x,
                    y: y,
                    width: box.width * imageSize.width,
                    height: box.height * imageSize.height
                ).integral
            }
        }

        let resultImage: CIImage
        switch mode {
        case .blur:      resultImage = applyBlur(to: ciImage, rects: pixelRects, intensity: clamped)
        case .pixelate:  resultImage = applyPixelate(to: ciImage, rects: pixelRects, intensity: clamped)
        case .blackBox:  resultImage = applyBlackBox(to: ciImage, rects: pixelRects)
        }

        guard let outputCG = sharedContext.createCGImage(resultImage, from: ciImage.extent) else {
            throw Error.encodeFailed
        }
        let outputUI = UIImage(
            cgImage: outputCG,
            scale: uiImage.scale,
            orientation: uiImage.imageOrientation
        )

        let outputData: Data?
        if outputFormat.lowercased() == "png" {
            outputData = outputUI.pngData()
        } else {
            outputData = outputUI.jpegData(compressionQuality: 0.92)
        }
        guard let bytes = outputData else { throw Error.encodeFailed }
        return bytes
    }

    static func redactFile(
        at inputURL: URL,
        boxes: [Box],
        mode: Mode,
        intensity: Double,
        outputURL: URL?
    ) throws -> URL {
        let data = try Data(contentsOf: inputURL)
        let outputFormat = inputURL.pathExtension.lowercased() == "png" ? "png" : "jpeg"
        let redacted = try redact(
            data: data, boxes: boxes, mode: mode,
            intensity: intensity, outputFormat: outputFormat
        )
        let destination: URL
        if let outputURL = outputURL {
            destination = outputURL
            try? FileManager.default.removeItem(at: destination)
        } else {
            destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("nsfw_redacted_\(UUID().uuidString).\(outputFormat)")
        }
        try redacted.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - Modes

    private static func applyBlur(to image: CIImage, rects: [CGRect], intensity: Double) -> CIImage {
        // Radius 1…50 px. CIGaussianBlur clamps internally past ~100.
        let radius = max(1.0, min(50.0, intensity * 50.0 + 1.0))
        var working = image
        for rect in rects {
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(radius)
            guard let blurred = filter.outputImage?.cropped(to: rect) else { continue }
            working = blurred.composited(over: working)
        }
        return working
    }

    private static func applyPixelate(to image: CIImage, rects: [CGRect], intensity: Double) -> CIImage {
        let blockSize = max(4.0, min(64.0, intensity * 64.0 + 4.0))
        var working = image
        for rect in rects {
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: rect.midX, y: rect.midY)
            filter.scale = Float(blockSize)
            guard let pixelated = filter.outputImage?.cropped(to: rect) else { continue }
            working = pixelated.composited(over: working)
        }
        return working
    }

    private static func applyBlackBox(to image: CIImage, rects: [CGRect]) -> CIImage {
        var working = image
        for rect in rects {
            let fill = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1.0))
                .cropped(to: rect)
            working = fill.composited(over: working)
        }
        return working
    }
}
