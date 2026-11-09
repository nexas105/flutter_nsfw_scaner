import Foundation
import CoreVideo

/// Protocol that all ML inference engines must conform to.
/// Swap CoreML -> TFLite -> ONNX without changing the scanner.
protocol MLEngine: AnyObject {
    var descriptor: ModelDescriptorNative { get }

    /// Load the model into memory (idempotent).
    func load() async throws

    /// Free memory.
    func unload()

    /// Run inference on one pixel buffer. Thread-safe; can be called concurrently.
    func classify(pixelBuffer: CVPixelBuffer) async throws -> NsfwClassification

    /// Run inference on a batch of pixel buffers in a single model call.
    /// Returns one NsfwClassification per input buffer, in the same order.
    /// Default implementation falls back to serial classify() calls so existing
    /// engines compile and work without modification.
    func classifyBatch(_ buffers: [CVPixelBuffer]) async throws -> [NsfwClassification]

    /// Optional: configure detection thresholds from ScanConfiguration.
    /// Default implementation is a no-op (classifiers don't need this).
    func configure(detectionConfidence: Float, iou: Float)

    /// Set the preferred compute units BEFORE `load()` is called. Engines that
    /// have already loaded with a different value should be unloaded by the
    /// caller before calling this. Default is a no-op.
    func setPreferredComputeUnits(_ units: ComputeUnitsPreference)

    /// The compute units the model was actually loaded with. Default `.all`
    /// for engines that don't track this.
    var loadedComputeUnits: ComputeUnitsPreference { get }
}

extension MLEngine {
    func configure(detectionConfidence: Float, iou: Float) {
        // No-op for classifier engines
    }

    func classifyBatch(_ buffers: [CVPixelBuffer]) async throws -> [NsfwClassification] {
        var results: [NsfwClassification] = []
        results.reserveCapacity(buffers.count)
        for buffer in buffers {
            results.append(try await classify(pixelBuffer: buffer))
        }
        return results
    }

    func setPreferredComputeUnits(_ units: ComputeUnitsPreference) {
        // No-op default for engines that don't expose compute-unit selection.
    }

    var loadedComputeUnits: ComputeUnitsPreference { .all }
}
