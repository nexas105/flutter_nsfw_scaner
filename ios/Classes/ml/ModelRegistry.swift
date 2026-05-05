import Foundation

typealias MLEngineFactory          = (ModelDescriptorNative) -> MLEngine
typealias MLDetectorEngineFactory  = (ModelDescriptorNative) -> MLDetectorEngine

/// Distinguishes classifier (`MLEngine`) and detector (`MLDetectorEngine`)
/// registrations. Persisted in `descriptor.metadata["kind"]` as well, but the
/// registry-side enum is the source of truth for routing.
enum ModelKind: String {
    case classifier
    case detector
}

/// Singleton registry of all available ML models.
/// Models are lazily loaded and cached until explicitly unloaded.
final class ModelRegistry {

    static let shared = ModelRegistry()
    private init() { registerBuiltins() }

    private var descriptors: [String: ModelDescriptorNative] = [:]
    private var factories:   [String: MLEngineFactory]       = [:]
    private var detectorFactories: [String: MLDetectorEngineFactory] = [:]
    private var kinds:       [String: ModelKind]             = [:]
    private var loaded:      [String: MLEngine]              = [:]
    private var loadedDetectors: [String: MLDetectorEngine]  = [:]
    private let lock = NSLock()

    // MARK: - Registration

    func register(
        descriptor: ModelDescriptorNative,
        factory: @escaping MLEngineFactory
    ) {
        lock.lock(); defer { lock.unlock() }
        descriptors[descriptor.id] = descriptor
        factories[descriptor.id]   = factory
        kinds[descriptor.id]       = .classifier
    }

    /// Register an object-detection (`MLDetectorEngine`) model. The descriptor
    /// SHOULD include `metadata["kind"] = "detector"` so the wire payload also
    /// reflects the kind for Dart consumers, but the registry is the source of
    /// truth and consults `kinds[id]` first.
    func register(
        detectorDescriptor descriptor: ModelDescriptorNative,
        factory: @escaping MLDetectorEngineFactory
    ) {
        lock.lock(); defer { lock.unlock() }
        descriptors[descriptor.id]       = descriptor
        detectorFactories[descriptor.id] = factory
        kinds[descriptor.id]             = .detector
    }

    func allDescriptors() -> [ModelDescriptorNative] {
        lock.lock(); defer { lock.unlock() }
        return Array(descriptors.values)
    }

    func descriptor(for id: String) -> ModelDescriptorNative? {
        lock.lock(); defer { lock.unlock() }
        return descriptors[id]
    }

    /// Returns whether `id` is registered as a classifier or detector model.
    /// `nil` if the id is unknown.
    func kind(for id: String) -> ModelKind? {
        lock.lock(); defer { lock.unlock() }
        return kinds[id]
    }

    // MARK: - Access

    func engine(for id: String) async throws -> MLEngine {
        return try await engine(for: id, computeUnits: .all)
    }

    /// Variant that lets callers pin a specific compute-units preference.
    /// If a cached engine exists with a different `loadedComputeUnits`, it is
    /// unloaded and recreated so the new preference takes effect.
    func engine(for id: String, computeUnits: ComputeUnitsPreference) async throws -> MLEngine {
        lock.lock()
        if let cached = loaded[id] {
            if cached.loadedComputeUnits == computeUnits {
                lock.unlock()
                return cached
            }
            // Mismatch → drop cached engine and rebuild below.
            loaded.removeValue(forKey: id)
            lock.unlock()
            cached.unload()
            lock.lock()
        }

        guard let factory    = factories[id],
              let descriptor = descriptors[id] else {
            lock.unlock()
            throw MLEngineError.modelNotFound(id)
        }
        lock.unlock()

        // Check if download required
        if descriptor.requiresDownload && !descriptor.isAvailable {
            throw MLEngineError.modelNotDownloaded(id)
        }

        let engine = factory(descriptor)
        engine.setPreferredComputeUnits(computeUnits)
        try await engine.load()

        lock.lock()
        loaded[id] = engine
        lock.unlock()

        return engine
    }

    func preload(_ id: String) async throws {
        if kind(for: id) == .detector {
            _ = try await detectorEngine(for: id, computeUnits: .all)
        } else {
            _ = try await engine(for: id)
        }
    }

    /// Variant of `engine(for:)` for detector-kind models. Mirrors the
    /// classifier path: cache by id, evict on compute-units mismatch, refuse
    /// to instantiate for an undownloaded model.
    func detectorEngine(for id: String, computeUnits: ComputeUnitsPreference = .all) async throws -> MLDetectorEngine {
        lock.lock()
        if let cached = loadedDetectors[id] {
            if cached.loadedComputeUnits == computeUnits {
                lock.unlock()
                return cached
            }
            loadedDetectors.removeValue(forKey: id)
            lock.unlock()
            cached.unload()
            lock.lock()
        }

        guard let factory    = detectorFactories[id],
              let descriptor = descriptors[id] else {
            lock.unlock()
            throw MLEngineError.modelNotFound(id)
        }
        lock.unlock()

        if descriptor.requiresDownload && !descriptor.isAvailable {
            throw MLEngineError.modelNotDownloaded(id)
        }

        let engine = factory(descriptor)
        engine.setPreferredComputeUnits(computeUnits)
        try await engine.load()

        lock.lock()
        loadedDetectors[id] = engine
        lock.unlock()

        return engine
    }

    func unloadAll() {
        lock.lock()
        let classifiers = Array(loaded.values)
        let detectors   = Array(loadedDetectors.values)
        loaded.removeAll()
        loadedDetectors.removeAll()
        lock.unlock()
        classifiers.forEach { $0.unload() }
        detectors.forEach   { $0.unload() }
    }

    /// Unload a specific model to free memory (e.g. before loading a different one)
    func unload(_ id: String) {
        lock.lock()
        let cls = loaded.removeValue(forKey: id)
        let det = loadedDetectors.removeValue(forKey: id)
        lock.unlock()
        cls?.unload()
        det?.unload()
    }

    // MARK: - Built-in models

    private func registerBuiltins() {
        // ── Bundled (included in app binary) ────────────────────────

        let openNsfw2 = ModelDescriptorNative(
            id:                 ModelIds.openNsfw2,
            displayName:        "OpenNSFW2 (Bundled)",
            description:        "Lightweight NSFW classifier — 11 MB, fast, good baseline.",
            version:            "1.0",
            bundleResourceName: "OpenNSFW2",
            metadata:           ["inputSize": 224, "framework": "CoreML"]
        )
        register(descriptor: openNsfw2) { CoreMLEngine(descriptor: $0) }

        // ── Downloadable (on-demand) ────────────────────────────────

        let falconsaiDefaultUrl = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/FalconsaiNSFW.mlmodelc.zip"
        let falconsai = ModelDescriptorNative(
            id:                 ModelIds.falconsai,
            displayName:        "Falconsai ViT NSFW",
            description:        "High-accuracy ViT classifier (98%). ~151 MB download.",
            version:            "1.0",
            bundleResourceName: "FalconsaiNSFW",
            metadata:           ["inputSize": 224, "framework": "CoreML"],
            downloadUrl:        UserDefaults.standard.string(forKey: "nsfw_model_url_\(ModelIds.falconsai)") ?? falconsaiDefaultUrl,
            downloadSizeBytes:  151_000_000
        )
        register(descriptor: falconsai) { CoreMLEngine(descriptor: $0) }

        let adamcoddDefaultUrl = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/AdamCoddNSFW.mlmodelc.zip"
        let adamcodd = ModelDescriptorNative(
            id:                 ModelIds.adamcodd,
            displayName:        "AdamCodd ViT NSFW",
            description:        "Highest-accuracy ViT-384 detector (AUC 0.9948). ~151 MB download.",
            version:            "1.0",
            bundleResourceName: "AdamCoddNSFW",
            metadata:           ["inputSize": 384, "framework": "CoreML"],
            downloadUrl:        UserDefaults.standard.string(forKey: "nsfw_model_url_\(ModelIds.adamcodd)") ?? adamcoddDefaultUrl,
            downloadSizeBytes:  151_000_000
        )
        register(descriptor: adamcodd) { CoreMLEngine(descriptor: $0) }

        // ── Detector model: NudeNet (downloadable) ──────────────────
        // The user hosts the converted artefact themselves. Default URL is a
        // placeholder following the same `models/<Name>.mlmodelc.zip` pattern
        // as the other downloadable models. Override at runtime via
        // `setModelDownloadUrl`.
        let nudenetDefaultUrl = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models/NudeNetDetector.mlmodelc.zip"
        let nudenet = ModelDescriptorNative(
            id:                 ModelIds.nudenet,
            displayName:        "NudeNet (Detection)",
            description:        "Body-part bounding-box detector. ~50 MB.",
            version:            "1.0",
            bundleResourceName: "NudeNetDetector",
            metadata: [
                "inputSize": 320,
                "framework": "CoreML",
                "kind":      "detector",
            ],
            downloadUrl:        UserDefaults.standard.string(forKey: "nsfw_model_url_\(ModelIds.nudenet)") ?? nudenetDefaultUrl,
            downloadSizeBytes:  50_000_000
        )
        register(detectorDescriptor: nudenet) { CoreMLDetectorEngine(descriptor: $0) }
    }

    // MARK: - Dynamic URL configuration

    /// Set the download URL for a model at runtime (persisted via UserDefaults).
    /// Call this before the model is needed.
    func setModelDownloadUrl(_ url: String, for modelId: String) {
        UserDefaults.standard.set(url, forKey: "nsfw_model_url_\(modelId)")
        // Re-register with updated URL
        lock.lock()
        if let desc = descriptors[modelId] {
            let _ = factories[modelId]
            lock.unlock()

            let updated = ModelDescriptorNative(
                id: desc.id,
                displayName: desc.displayName,
                description: desc.description,
                version: desc.version,
                bundleResourceName: desc.bundleResourceName,
                metadata: desc.metadata,
                downloadUrl: url,
                downloadSizeBytes: desc.downloadSizeBytes
            )
            lock.lock()
            descriptors[modelId] = updated
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
