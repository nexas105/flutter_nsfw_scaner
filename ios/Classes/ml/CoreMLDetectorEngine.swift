import Foundation
import CoreML
import Vision
import CoreVideo
import os

/// CoreML + Vision object-detection engine for NudeNet-style models.
/// Output is a list of `BodyPartDetectionNative` (label + confidence + box).
///
/// Coordinate convention: Vision's `boundingBox` origin is **bottom-left**.
/// We flip to top-left here so the rest of the pipeline (Dart, Android) sees
/// a single consistent system.
final class CoreMLDetectorEngine: MLDetectorEngine {

    let descriptor: ModelDescriptorNative

    private var visionModel: VNCoreMLModel?
    private var mlModel: MLModel?

    /// Re-used per request because VNCoreMLRequest is not safe to share concurrently.
    private var cachedRequest: VNCoreMLRequest?
    private let requestLock = OSAllocatedUnfairLock()
    private let loadLock = OSAllocatedUnfairLock()

    private var preferredComputeUnits: ComputeUnitsPreference = .all
    private var actualLoadedComputeUnits: ComputeUnitsPreference = .all

    /// NudeNet default. Overridable via `setMinConfidence`.
    private var minConfidence: Float = 0.25

    init(descriptor: ModelDescriptorNative) {
        self.descriptor = descriptor
    }

    // MARK: - MLDetectorEngine

    func setPreferredComputeUnits(_ units: ComputeUnitsPreference) {
        loadLock.withLock {
            if visionModel != nil && actualLoadedComputeUnits == units { return }
            preferredComputeUnits = units
        }
    }

    var loadedComputeUnits: ComputeUnitsPreference { actualLoadedComputeUnits }

    func setMinConfidence(_ min: Float) {
        loadLock.withLock { minConfidence = max(0, min) }
    }

    func load() async throws {
        let earlyDesired: ComputeUnitsPreference? = loadLock.withLock {
            visionModel == nil ? preferredComputeUnits : nil
        }
        guard let desiredUnits = earlyDesired else { return }

        guard descriptor.bundleResourceName != nil || descriptor.customAssetPath != nil else {
            throw MLEngineError.modelNotFound(descriptor.id)
        }
        let resourceName = descriptor.bundleResourceName ?? descriptor.id

        // Reuse the classifier-engine resolver — same search paths.
        guard let modelURL = CoreMLEngine.findModelURLStatic(
            named: resourceName,
            customAssetPath: descriptor.customAssetPath
        ) else {
            NSLog("[NSFW] DETECTOR MODEL NOT FOUND: %@", resourceName)
            throw MLEngineError.modelNotFound(resourceName)
        }

        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            compiledURL = try await MLModel.compileModel(at: modelURL)
        }

        let config = MLModelConfiguration()
        config.computeUnits = desiredUnits.mlComputeUnits

        let loaded = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        let vnModel = try VNCoreMLModel(for: loaded)

        let req = VNCoreMLRequest(model: vnModel)
        req.imageCropAndScaleOption = .scaleFit

        loadLock.withLock {
            self.visionModel              = vnModel
            self.mlModel                  = loaded
            self.cachedRequest            = req
            self.actualLoadedComputeUnits = desiredUnits
        }
        NSLog("[NSFW] CoreMLDetectorEngine loaded %@ (computeUnits=%@)",
              descriptor.id, desiredUnits.rawValue)
    }

    func unload() {
        loadLock.withLock {
            visionModel   = nil
            mlModel       = nil
            cachedRequest = nil
        }
    }

    func detect(pixelBuffer: CVPixelBuffer) async throws -> [BodyPartDetectionNative] {
        let (request, threshold): (VNCoreMLRequest?, Float) = loadLock.withLock {
            (cachedRequest, minConfidence)
        }
        guard let request = request else { throw MLEngineError.notLoaded }

        // withLockUnchecked: lock-guarded body captures CVPixelBuffer
        // (non-Sendable). Serialisation is provided by the lock itself.
        return try requestLock.withLockUnchecked { () throws -> [BodyPartDetectionNative] in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try handler.perform([request])

            guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                return []
            }

            var detections: [BodyPartDetectionNative] = []
            detections.reserveCapacity(observations.count)

            for obs in observations {
                // Pick the top label for this box.
                let topLabel = obs.labels.first
                let labelName = topLabel?.identifier ?? "UNKNOWN"
                let confidence: Float = topLabel?.confidence ?? obs.confidence
                if confidence < threshold { continue }

                // Vision boundingBox: origin bottom-left, normalized [0, 1].
                // Convert to top-left for cross-platform consistency.
                let bb = obs.boundingBox
                let x      = Float(bb.origin.x)
                let yTop   = Float(1.0 - bb.origin.y - bb.size.height)
                let width  = Float(bb.size.width)
                let height = Float(bb.size.height)

                let agg = BodyPartDetectionNative.aggregateCategory(forLabel: labelName)
                detections.append(BodyPartDetectionNative(
                    label:              labelName,
                    confidence:         confidence,
                    x:                  max(0, min(1, x)),
                    y:                  max(0, min(1, yTop)),
                    width:              max(0, min(1, width)),
                    height:             max(0, min(1, height)),
                    aggregatedCategory: agg
                ))
            }
            return detections
        }
    }
}
