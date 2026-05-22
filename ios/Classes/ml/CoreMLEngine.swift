import Foundation
import CoreML
import Vision
import CoreVideo
import os

/// CoreML + Vision inference engine.
/// Uses VNCoreMLRequest for efficient on-device classification.
/// Compatible with iOS 14.0+.
final class CoreMLEngine: MLEngine {

    /// Dedicated os_log category for CoreML lifecycle / compute-unit events.
    /// Visible in Console.app under subsystem `com.nsfw_detect_ios.CoreML`.
    private static let log = OSLog(subsystem: "com.nsfw_detect_ios", category: "NSFW.CoreML")

    /// Window after `batchDisabled` was set during which a single recovery
    /// attempt is allowed. If the trial succeeds, batch mode is fully
    /// re-enabled; on failure the timer is reset. See Task #19.
    private static let batchRecoveryWindow: TimeInterval = 5 * 60  // 5 minutes

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
    /// Wall-clock timestamp of the most recent batch failure. Used by the
    /// 5-minute recovery window — see `tryBatchRecoveryIfNeeded()`.
    private var lastBatchFailureAt: Date?

    /// Preferred compute units; consulted at `load()` time.
    private var preferredComputeUnits: ComputeUnitsPreference = .all
    /// What the currently loaded model was actually loaded with. Stays `.all`
    /// until a successful load completes.
    private var actualLoadedComputeUnits: ComputeUnitsPreference = .all

    /// Reused VNCoreMLRequest for the Vision per-image fallback path.
    /// Built once at load() time; nil-ed in unload(). Guarded by `requestLock`
    /// because VNCoreMLRequest is not safe to use concurrently.
    private var cachedRequest: VNCoreMLRequest?
    private let requestLock = OSAllocatedUnfairLock()

    private let loadLock = OSAllocatedUnfairLock()

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
        let earlyDesiredUnits: ComputeUnitsPreference? = loadLock.withLock {
            visionModel == nil ? preferredComputeUnits : nil
        }
        guard let desiredUnits = earlyDesiredUnits else { return }

        guard descriptor.bundleResourceName != nil || descriptor.customAssetPath != nil else {
            NSLog("[NSFW] Model has no bundleResourceName or customAssetPath: %@", descriptor.id)
            throw MLEngineError.modelNotFound(descriptor.id)
        }
        let resourceName = descriptor.bundleResourceName ?? descriptor.id

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
        // Surface compute-units selection on the os_log path too (#20) so
        // diagnostics-tooling can correlate inference behaviour with
        // engine selection without parsing NSLog stderr.
        os_log("Loading MLModel — desired computeUnits=%{public}@",
               log: CoreMLEngine.log, type: .info, desiredUnits.rawValue)
        let loadedModel: MLModel
        do {
            loadedModel = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        } catch {
            // Apple silently downgrades unsupported compute-units selections
            // (e.g. .cpuAndNeuralEngine on the simulator), but a hard load
            // error on the desired selection is worth a loud breadcrumb.
            os_log("MLModel.load failed for computeUnits=%{public}@ — %{public}@",
                   log: CoreMLEngine.log, type: .error,
                   desiredUnits.rawValue, error.localizedDescription)
            throw error
        }
        NSLog("[NSFW] Creating VNCoreMLModel...")
        let model = try VNCoreMLModel(for: loadedModel)
        NSLog("[NSFW] Model ready!")
        os_log("MLModel ready — actual computeUnits=%{public}@",
               log: CoreMLEngine.log, type: .info, desiredUnits.rawValue)

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

        loadLock.withLock {
            visionModel              = model
            self.mlModel             = loadedModel
            inputFeatureName         = inName
            outputFeatureName        = outName
            cachedRequest            = req
            actualLoadedComputeUnits = desiredUnits
        }
    }

    func unload() {
        loadLock.withLock {
            visionModel      = nil
            mlModel          = nil
            inputFeatureName = nil
            outputFeatureName = nil
            cachedRequest    = nil
        }
    }

    func classify(pixelBuffer: CVPixelBuffer) async throws -> NsfwClassification {
        let request = loadLock.withLock { cachedRequest }
        guard let request = request else { throw MLEngineError.notLoaded }

        // VNCoreMLRequest is not safe to use concurrently — serialize via the
        // request lock. The locked region is fully synchronous (no await),
        // so holding `os_unfair_lock` across it is safe.
        // `withLockUnchecked` (vs `withLock`) skips the Sendable check on
        // body+result. Required here because CVPixelBuffer isn't Sendable —
        // the lock provides the exclusive access guarantee instead.
        return try requestLock.withLockUnchecked { () throws -> NsfwClassification in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try handler.perform([request])

            guard let results = request.results, !results.isEmpty else { return .unknown }

            // Case 1: classifier models emit `VNClassificationObservation`.
            // Vision passes through raw logits for ViT classifiers
            // (Falconsai/AdamCodd) — apply softmax client-side so downstream
            // consumers see [0, 1].
            if let classificationResults = results as? [VNClassificationObservation] {
                let raws  = classificationResults.map { Float($0.confidence) }
                let probs = Self.softmax(raws)
                let labels = zip(classificationResults, probs)
                    .sorted { $0.1 > $1.1 }
                    .map { (obs, prob) in
                        NsfwClassification.Label(
                            category:   NsfwClassification.canonicalCategory(obs.identifier),
                            confidence: prob
                        )
                    }
                return NsfwClassification(labels: labels)
            }

            // Case 2: feature-value outputs with MultiArray (e.g. OpenNSFW2:
            // [1, 2] where index 0 = SFW, index 1 = NSFW).
            if let featureResult = results.first as? VNCoreMLFeatureValueObservation,
               let multiArray = featureResult.featureValue.multiArrayValue {
                let labels = self.parseMultiArrayOutput(multiArray)
                if !labels.isEmpty {
                    return NsfwClassification(labels: labels)
                }
            }

            return .unknown
        }
    }

    // MARK: - Batch inference

    /// Submits all pixel buffers to the model in a single MLModel.predictions(from:) call,
    /// bypassing the per-image Vision overhead.
    ///
    /// Failure modes:
    ///   • After 2 consecutive failures, batch mode is disabled and the
    ///     failure timestamp is recorded.
    ///   • While disabled, the engine periodically (every 5 min — see
    ///     `batchRecoveryWindow`) allows ONE trial batch through. If the
    ///     trial succeeds, batch mode is fully re-enabled. If it fails,
    ///     the timer is reset for another 5-minute window.
    ///
    /// All counter / timer / `batchDisabled` mutations go through
    /// `loadLock` so concurrent callers can't double-trigger or race on
    /// the recovery trial.
    func classifyBatch(_ buffers: [CVPixelBuffer]) async throws -> [NsfwClassification] {
        guard !buffers.isEmpty else { return [] }

        // Snapshot of relevant state. The recovery-trial flag is computed
        // under the same lock so we never see a stale "disabled" while
        // another thread is mid-recovery.
        let snapshot: (MLModel?, String?, String?, Bool, Bool) = loadLock.withLock {
            let recoveryTrial: Bool = {
                guard batchDisabled, let last = lastBatchFailureAt else { return false }
                return Date().timeIntervalSince(last) >= Self.batchRecoveryWindow
            }()
            return (mlModel, inputFeatureName, outputFeatureName, batchDisabled, recoveryTrial)
        }
        let model = snapshot.0
        let inName = snapshot.1
        let outName = snapshot.2
        let disabled = snapshot.3
        let isRecoveryTrial = snapshot.4

        // Kill switch or missing feature names → fall through to serial Vision path.
        // Exception: if a recovery trial is due, attempt the batch anyway.
        let shouldAttemptBatch = (!disabled || isRecoveryTrial)
        guard shouldAttemptBatch, let model = model, let inName = inName, let outName = outName else {
            return try await serialClassifyBatch(buffers)
        }

        if isRecoveryTrial {
            os_log("Batch recovery: 5-min window elapsed, attempting trial batch",
                   log: CoreMLEngine.log, type: .info)
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

            // Success: clear the failure counter and (if this was a trial)
            // re-enable batch mode.
            loadLock.withLock {
                consecutiveBatchFailures = 0
                if isRecoveryTrial {
                    batchDisabled      = false
                    lastBatchFailureAt = nil
                    NSLog("[NSFW] Batch recovery succeeded — batch mode re-enabled")
                    os_log("Batch recovery succeeded — batch mode re-enabled",
                           log: CoreMLEngine.log, type: .info)
                }
            }
            return results

        } catch {
            // Trial failed → keep batch disabled and reset the timer
            // (lastBatchFailureAt = Date()) so another 5 minutes pass.
            // First-time failures bump the counter; ≥2 → disable mode.
            loadLock.withLock {
                consecutiveBatchFailures += 1
                lastBatchFailureAt = Date()
                if isRecoveryTrial {
                    NSLog("[NSFW] Batch recovery FAILED — staying on Vision path; will retry in %.0f min",
                          Self.batchRecoveryWindow / 60.0)
                    os_log("Batch recovery failed — Vision path retained, next retry in %{public}.0f minutes",
                           log: CoreMLEngine.log, type: .error,
                           Self.batchRecoveryWindow / 60.0)
                } else if consecutiveBatchFailures >= 2 {
                    batchDisabled = true
                    NSLog("[NSFW] Batch prediction disabled after 2 failures — reverting to Vision path (recovery in %.0f min)",
                          Self.batchRecoveryWindow / 60.0)
                    os_log("Batch prediction disabled after 2 failures — recovery scheduled in %{public}.0f minutes",
                           log: CoreMLEngine.log, type: .error,
                           Self.batchRecoveryWindow / 60.0)
                }
            }
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

    /// If the pair already looks like probabilities (both in `[0, 1]` and
    /// summing to ~1), return as-is. Otherwise treat as logits and apply a
    /// 2-element softmax. OpenNSFW2 emits softmaxed values straight from
    /// its TFLite/CoreML graph — running softmax on those would compress
    /// 0.95 → 0.71 and shift NSFW classifications below the 0.7 threshold.
    /// ViT classifiers (AdamCodd, Falconsai) emit raw logits and need it.
    private static func normaliseConfidencePair(_ a: Float, _ b: Float) -> (Float, Float) {
        let sum = a + b
        let bothInRange = a >= 0 && a <= 1 && b >= 0 && b <= 1
        let looksLikeProbs = bothInRange && abs(sum - 1.0) < 0.05
        if looksLikeProbs { return (a, b) }
        let probs = softmax([a, b])
        return (probs[0], probs[1])
    }

    /// Numerically-stable softmax. Subtracts the max before exponentiation to
    /// avoid overflow when logits are large positive (common with ViT).
    private static func softmax(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let maxVal = values.max() ?? 0
        let exps   = values.map { Foundation.exp($0 - maxVal) }
        let sum    = exps.reduce(0, +)
        guard sum > 0 else {
            return Array(repeating: 1.0 / Float(values.count), count: values.count)
        }
        return exps.map { $0 / sum }
    }

    /// Parse MultiArray output. All currently supported models are 2-class:
    ///   - OpenNSFW2:   [safe, nudity]                — already softmaxed
    ///   - Falconsai:   [normal, nsfw]   (semantic: [safe, nudity]) — RAW LOGITS
    ///   - AdamCodd:    [sfw, nsfw]      (semantic: [safe, nudity]) — RAW LOGITS
    ///
    /// `classifier_config`-built ViT models emit raw logits in the
    /// MultiArray. The batch-prediction path goes through here (Vision's
    /// VNClassificationObservation only fires on the per-image fallback),
    /// so we detect logits-vs-probabilities at parse time and softmax
    /// when needed. Without this, AdamCodd / Falconsai produce values
    /// like nudity=357%, safe=-240% in batched scans.
    private func parseMultiArrayOutput(_ array: MLMultiArray) -> [NsfwClassification.Label] {
        let count = array.count

        if count == 2 {
            let raw0 = Float(truncating: array[0])
            let raw1 = Float(truncating: array[1])
            let (sfwConf, nsfwConf) = Self.normaliseConfidencePair(raw0, raw1)
            return [
                NsfwClassification.Label(category: "safe",   confidence: sfwConf),
                NsfwClassification.Label(category: "nudity", confidence: nsfwConf),
            ].sorted { $0.confidence > $1.confidence }
        }

        // Defensive fallback for unexpected output shapes — collapse to a
        // 2-class view by treating index 0 as safe and the last as nsfw.
        if count > 0 {
            let raw0   = Float(truncating: array[0])
            let raw1   = count > 1 ? Float(truncating: array[count - 1]) : (1.0 - raw0)
            let (sfwConf, nsfwConf) = Self.normaliseConfidencePair(raw0, raw1)
            return [
                NsfwClassification.Label(category: "safe",   confidence: sfwConf),
                NsfwClassification.Label(category: "nudity", confidence: nsfwConf),
            ].sorted { $0.confidence > $1.confidence }
        }

        return []
    }

    // MARK: - Helpers

    /// Shared model URL finder.
    static func findModelURLStatic(named name: String, customAssetPath: String? = nil) -> URL? {
        return _findModelURL(named: name, referenceClass: CoreMLEngine.self, customAssetPath: customAssetPath)
    }

    private func findModelURL(named name: String) -> URL? {
        return CoreMLEngine._findModelURL(named: name, referenceClass: CoreMLEngine.self, customAssetPath: descriptor.customAssetPath)
    }

    private static func _findModelURL(named name: String, referenceClass: AnyClass, customAssetPath: String?) -> URL? {
        // -1. Custom-registered model — assetPath is absolute, already
        // validated by ScanMethodHandler.registerModel (sandbox + existence).
        // No further extension search: caller pointed at the exact artefact.
        if let custom = customAssetPath {
            return URL(fileURLWithPath: custom)
        }

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
