import Foundation
import CoreML
import Vision
import CoreVideo

/// CoreML + Vision inference engine.
/// Uses VNCoreMLRequest for efficient on-device classification.
/// Compatible with iOS 14.0+.
final class CoreMLEngine: MLEngine {

    let descriptor: ModelDescriptorNative

    private var visionModel: VNCoreMLModel?
    /// Raw MLModel retained for direct batch inference (bypasses Vision overhead).
    private var mlModel: MLModel?
    /// Pixel-buffer input feature name, discovered from modelDescription at load() time.
    private var inputFeatureName: String?
    /// MultiArray output feature name, discovered from modelDescription at load() time.
    private var outputFeatureName: String?
    /// Counts consecutive batch failures — disables batch after 2 to protect the session.
    private var consecutiveBatchFailures = 0
    private var batchDisabled = false

    /// Preferred compute units; consulted at `load()` time.
    private var preferredComputeUnits: ComputeUnitsPreference = .all
    /// What the currently loaded model was actually loaded with. Stays `.all`
    /// until a successful load completes.
    private var actualLoadedComputeUnits: ComputeUnitsPreference = .all

    /// Reused VNCoreMLRequest for the Vision per-image fallback path.
    /// Built once at load() time; nil-ed in unload(). Guarded by `requestLock`
    /// because VNCoreMLRequest is not safe to use concurrently.
    private var cachedRequest: VNCoreMLRequest?
    private let requestLock = NSLock()

    private let loadLock = NSLock()

    init(descriptor: ModelDescriptorNative) {
        self.descriptor = descriptor
    }

    // MARK: - MLEngine

    func setPreferredComputeUnits(_ units: ComputeUnitsPreference) {
        loadLock.lock()
        defer { loadLock.unlock() }
        // If already loaded with this value, nothing to do.
        if visionModel != nil && actualLoadedComputeUnits == units { return }
        preferredComputeUnits = units
    }

    var loadedComputeUnits: ComputeUnitsPreference { actualLoadedComputeUnits }

    func load() async throws {
        // Guard: already loaded
        loadLock.lock()
        if visionModel != nil { loadLock.unlock(); return }
        let desiredUnits = preferredComputeUnits
        loadLock.unlock()

        guard let resourceName = descriptor.bundleResourceName else {
            NSLog("[NSFW] Model has no bundleResourceName: %@", descriptor.id)
            throw MLEngineError.modelNotFound(descriptor.id)
        }

        NSLog("[NSFW] Looking for model resource: %@", resourceName)
        NSLog("[NSFW] Plugin bundle path: %@", Bundle(for: CoreMLEngine.self).bundlePath)
        NSLog("[NSFW] Main bundle path: %@", Bundle.main.bundlePath)

        guard let modelURL = findModelURL(named: resourceName) else {
            NSLog("[NSFW] MODEL NOT FOUND: %@", resourceName)
            // List what IS in the plugin bundle for debugging
            let pluginBundle = Bundle(for: CoreMLEngine.self)
            if let resources = try? FileManager.default.contentsOfDirectory(atPath: pluginBundle.bundlePath) {
                NSLog("[NSFW] Plugin bundle contents: %@", resources.joined(separator: ", "))
            }
            throw MLEngineError.modelNotFound(resourceName)
        }

        NSLog("[NSFW] Model found at: %@", modelURL.path)

        // Compile if needed (.mlmodel / .mlpackage source); .mlmodelc is already compiled.
        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            NSLog("[NSFW] Compiling model from %@...", modelURL.pathExtension)
            compiledURL = try await MLModel.compileModel(at: modelURL)
            NSLog("[NSFW] Model compiled to: %@", compiledURL.path)
        }

        let config = MLModelConfiguration()
        config.computeUnits = desiredUnits.mlComputeUnits

        NSLog("[NSFW] Loading MLModel (computeUnits=%@)...", desiredUnits.rawValue)
        let loadedModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        NSLog("[NSFW] Creating VNCoreMLModel...")
        let model = try VNCoreMLModel(for: loadedModel)
        NSLog("[NSFW] Model ready!")

        // Build a single reusable Vision request so the per-image fallback
        // path doesn't allocate one per call.
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .scaleFit

        // Discover input and output feature names for the direct batch API.
        let inName = loadedModel.modelDescription.inputDescriptionsByName
            .first(where: { $0.value.type == .image })?.key
            ?? loadedModel.modelDescription.inputDescriptionsByName.first?.key
        let outName = loadedModel.modelDescription.outputDescriptionsByName
            .first(where: { $0.value.type == .multiArray })?.key
        NSLog("[NSFW] Batch feature names — input: %@, output: %@",
              inName ?? "nil", outName ?? "nil")

        loadLock.lock()
        visionModel              = model
        self.mlModel             = loadedModel
        inputFeatureName         = inName
        outputFeatureName        = outName
        cachedRequest            = req
        actualLoadedComputeUnits = desiredUnits
        loadLock.unlock()
    }

    func unload() {
        loadLock.lock()
        visionModel      = nil
        mlModel          = nil
        inputFeatureName = nil
        outputFeatureName = nil
        cachedRequest    = nil
        loadLock.unlock()
    }

    func classify(pixelBuffer: CVPixelBuffer) async throws -> NsfwClassification {
        loadLock.lock()
        let request = cachedRequest
        loadLock.unlock()

        guard let request = request else { throw MLEngineError.notLoaded }

        // VNCoreMLRequest is not safe to use concurrently — serialize.
        requestLock.lock()
        defer { requestLock.unlock() }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        guard let results = request.results, !results.isEmpty else { return .unknown }

        // Case 1: Model outputs VNClassificationObservation (classifier models)
        if let classificationResults = results as? [VNClassificationObservation] {
            let sorted = classificationResults.sorted { $0.confidence > $1.confidence }
            let labels = sorted.map {
                NsfwClassification.Label(
                    category:   NsfwClassification.canonicalCategory($0.identifier),
                    confidence: $0.confidence
                )
            }
            return NsfwClassification(labels: labels)
        }

        // Case 2: Model outputs VNCoreMLFeatureValueObservation with MultiArray
        // (e.g. OpenNSFW2: [1, 2] array where index 0 = SFW, index 1 = NSFW)
        if let featureResult = results.first as? VNCoreMLFeatureValueObservation,
           let multiArray = featureResult.featureValue.multiArrayValue {
            let labels = self.parseMultiArrayOutput(multiArray)
            if !labels.isEmpty {
                return NsfwClassification(labels: labels)
            }
        }

        return .unknown
    }

    // MARK: - Batch inference

    /// Submits all pixel buffers to the model in a single MLModel.predictions(from:) call,
    /// bypassing the per-image Vision overhead. Falls back to the serial Vision path after
    /// two consecutive failures so a session is never silently broken.
    func classifyBatch(_ buffers: [CVPixelBuffer]) async throws -> [NsfwClassification] {
        guard !buffers.isEmpty else { return [] }

        loadLock.lock()
        let model      = mlModel
        let inName     = inputFeatureName
        let outName    = outputFeatureName
        let disabled   = batchDisabled
        loadLock.unlock()

        // Kill switch or missing feature names → fall through to serial Vision path
        guard !disabled, let model = model, let inName = inName, let outName = outName else {
            return try await serialClassifyBatch(buffers)
        }

        do {
            let providers = buffers.map { PixelBufferFeatureProvider(pixelBuffer: $0, featureName: inName) }
            let batch     = MLArrayBatchProvider(array: providers)
            let output    = try model.predictions(from: batch, options: MLPredictionOptions())

            guard output.count == buffers.count else {
                throw MLEngineError.batchSizeMismatch(expected: buffers.count, got: output.count)
            }

            let results: [NsfwClassification] = (0..<output.count).map { i in
                guard let arr = output.features(at: i).featureValue(for: outName)?.multiArrayValue else {
                    return .unknown
                }
                let labels = self.parseMultiArrayOutput(arr)
                return labels.isEmpty ? .unknown : NsfwClassification(labels: labels)
            }

            loadLock.lock()
            consecutiveBatchFailures = 0
            loadLock.unlock()

            return results

        } catch {
            loadLock.lock()
            consecutiveBatchFailures += 1
            if consecutiveBatchFailures >= 2 {
                batchDisabled = true
                NSLog("[NSFW] Batch prediction disabled after 2 failures — reverting to Vision path")
            }
            loadLock.unlock()

            NSLog("[NSFW] Batch failed (size %d): %@ — falling back to per-asset", buffers.count, error.localizedDescription)
            return try await serialClassifyBatch(buffers)
        }
    }

    /// Serial Vision fallback — identical to the default protocol extension,
    /// kept here so CoreMLEngine can call it without `super` (which isn't valid
    /// for protocol extension defaults in Swift).
    private func serialClassifyBatch(_ buffers: [CVPixelBuffer]) async throws -> [NsfwClassification] {
        var results: [NsfwClassification] = []
        results.reserveCapacity(buffers.count)
        for buffer in buffers {
            results.append(try await classify(pixelBuffer: buffer))
        }
        return results
    }

    /// Parse MultiArray output with model-specific mappings when needed.
    private func parseMultiArrayOutput(_ array: MLMultiArray) -> [NsfwClassification.Label] {
        if descriptor.id == ModelIds.adamcodd {
            let labels = Self.parseAdamCoddMultiArrayOutput(array)
            if !labels.isEmpty {
                return labels
            }
        }
        return Self.parseGenericMultiArrayOutput(array)
    }

    /// Parse MultiArray output from models like OpenNSFW2.
    /// Expected shape: [1, 2] where [SFW_probability, NSFW_probability]
    /// Also handles shape [1, N] for models with more categories.
    private static func parseGenericMultiArrayOutput(_ array: MLMultiArray) -> [NsfwClassification.Label] {
        let count = array.count

        if count == 2 {
            // OpenNSFW2 format: [SFW, NSFW]
            let sfwConf  = Float(truncating: array[0])
            let nsfwConf = Float(truncating: array[1])
            return [
                NsfwClassification.Label(category: "safe",   confidence: sfwConf),
                NsfwClassification.Label(category: "nudity", confidence: nsfwConf),
            ].sorted { $0.confidence > $1.confidence }
        }

        if count >= 5 {
            // 5-class models: [safe, suggestive, nudity, explicitNudity, unknown]
            let categories = ["safe", "suggestive", "nudity", "explicitNudity", "unknown"]
            var labels: [NsfwClassification.Label] = []
            for i in 0..<min(count, categories.count) {
                let conf = Float(truncating: array[i])
                labels.append(NsfwClassification.Label(category: categories[i], confidence: conf))
            }
            return labels.sorted { $0.confidence > $1.confidence }
        }

        // Fallback: treat index 0 as safe, last as nsfw
        if count > 0 {
            let sfwConf  = Float(truncating: array[0])
            let nsfwConf = count > 1 ? Float(truncating: array[count - 1]) : (1.0 - sfwConf)
            return [
                NsfwClassification.Label(category: "safe",   confidence: sfwConf),
                NsfwClassification.Label(category: "nudity", confidence: nsfwConf),
            ].sorted { $0.confidence > $1.confidence }
        }

        return []
    }

    /// AdamCodd ViT (5 logits): [drawings, hentai, neutral, porn, sexy]
    /// Collapses source labels into the plugin's canonical categories.
    private static func parseAdamCoddMultiArrayOutput(_ array: MLMultiArray) -> [NsfwClassification.Label] {
        guard array.count >= 5 else { return [] }

        let drawings   = Float(truncating: array[0])
        let hentai     = Float(truncating: array[1])
        let neutral    = Float(truncating: array[2])
        let porn       = Float(truncating: array[3])
        let sexy       = Float(truncating: array[4])

        let safe       = max(drawings, neutral)
        let suggestive = sexy
        let nudity     = hentai
        let explicit   = porn

        return [
            NsfwClassification.Label(category: "safe", confidence: safe),
            NsfwClassification.Label(category: "suggestive", confidence: suggestive),
            NsfwClassification.Label(category: "nudity", confidence: nudity),
            NsfwClassification.Label(category: "explicitNudity", confidence: explicit),
        ].sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Helpers

    /// Shared model URL finder.
    static func findModelURLStatic(named name: String) -> URL? {
        return _findModelURL(named: name, referenceClass: CoreMLEngine.self)
    }

    private func findModelURL(named name: String) -> URL? {
        return CoreMLEngine._findModelURL(named: name, referenceClass: CoreMLEngine.self)
    }

    private static func _findModelURL(named name: String, referenceClass: AnyClass) -> URL? {
        // 0. Check downloaded models directory first
        if let downloadedURL = ModelDownloadManager.shared.localURL(for: name) {
            return downloadedURL
        }

        let extensions     = ["mlmodelc", "mlpackage", "mlmodel"]
        let pluginBundle   = Bundle(for: referenceClass)
        let searchBundles: [Bundle] = [pluginBundle, Bundle.main]

        // 1. Standard bundle resource lookup
        for bundle in searchBundles {
            for ext in extensions {
                if let url = bundle.url(forResource: name, withExtension: ext) {
                    return url
                }
            }
        }

        // 2. Direct path scan inside plugin framework (CocoaPods resource_bundles)
        for ext in extensions {
            let directURL = pluginBundle.bundleURL.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: directURL.path) {
                return directURL
            }
        }

        // 3. Check for a nested resource bundle (e.g. nsfw_detect_ios.bundle)
        for bundle in searchBundles {
            if let resourceBundleURL = bundle.url(forResource: "nsfw_detect_ios", withExtension: "bundle"),
               let resourceBundle = Bundle(url: resourceBundleURL) {
                for ext in extensions {
                    if let url = resourceBundle.url(forResource: name, withExtension: ext) {
                        return url
                    }
                }
            }
        }

        // 4. Search all framework bundles
        if let frameworksPath = Bundle.main.privateFrameworksPath {
            let frameworksURL = URL(fileURLWithPath: frameworksPath)
            if let contents = try? FileManager.default.contentsOfDirectory(at: frameworksURL, includingPropertiesForKeys: nil) {
                for frameworkURL in contents where frameworkURL.pathExtension == "framework" {
                    let fwBundle = Bundle(url: frameworkURL)
                    for ext in extensions {
                        let modelURL = frameworkURL.appendingPathComponent("\(name).\(ext)")
                        if FileManager.default.fileExists(atPath: modelURL.path) {
                            return modelURL
                        }
                        if let url = fwBundle?.url(forResource: name, withExtension: ext) {
                            return url
                        }
                    }
                }
            }
        }

        return nil
    }
}

enum MLEngineError: Error, LocalizedError {
    case modelNotFound(String)
    case modelNotDownloaded(String)
    case notLoaded
    case invalidOutput
    case batchSizeMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "ML model not found: \(id)"
        case .modelNotDownloaded(let id): return "ML model not downloaded: \(id). Download it first."
        case .notLoaded: return "ML model not loaded. Call load() first."
        case .invalidOutput: return "ML model returned invalid output."
        case .batchSizeMismatch(let e, let g): return "Batch output count mismatch: expected \(e), got \(g)."
        }
    }
}

// MARK: - PixelBufferFeatureProvider

/// Lightweight MLFeatureProvider wrapping a single CVPixelBuffer.
/// Used by CoreMLEngine.classifyBatch to build MLArrayBatchProvider inputs.
private final class PixelBufferFeatureProvider: NSObject, MLFeatureProvider {
    let pixelBuffer: CVPixelBuffer
    let featureName: String

    init(pixelBuffer: CVPixelBuffer, featureName: String) {
        self.pixelBuffer = pixelBuffer
        self.featureName = featureName
    }

    var featureNames: Set<String> { [featureName] }

    func featureValue(for name: String) -> MLFeatureValue? {
        name == featureName ? MLFeatureValue(pixelBuffer: pixelBuffer) : nil
    }
}
