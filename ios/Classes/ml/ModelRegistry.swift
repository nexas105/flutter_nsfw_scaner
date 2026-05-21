import Foundation
import os

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
    private let lock = OSAllocatedUnfairLock()

    // MARK: - Registration

    func register(
        descriptor: ModelDescriptorNative,
        factory: @escaping MLEngineFactory
    ) {
        lock.withLock {
            descriptors[descriptor.id] = descriptor
            factories[descriptor.id]   = factory
            kinds[descriptor.id]       = .classifier
        }
    }

    /// Register an object-detection (`MLDetectorEngine`) model. The descriptor
    /// SHOULD include `metadata["kind"] = "detector"` so the wire payload also
    /// reflects the kind for Dart consumers, but the registry is the source of
    /// truth and consults `kinds[id]` first.
    func register(
        detectorDescriptor descriptor: ModelDescriptorNative,
        factory: @escaping MLDetectorEngineFactory
    ) {
        lock.withLock {
            descriptors[descriptor.id]       = descriptor
            detectorFactories[descriptor.id] = factory
            kinds[descriptor.id]             = .detector
        }
    }

    func allDescriptors() -> [ModelDescriptorNative] {
        lock.withLock { Array(descriptors.values) }
    }

    func descriptor(for id: String) -> ModelDescriptorNative? {
        lock.withLock { descriptors[id] }
    }

    /// Returns whether `id` is registered as a classifier or detector model.
    /// `nil` if the id is unknown.
    func kind(for id: String) -> ModelKind? {
        lock.withLock { kinds[id] }
    }

    // MARK: - Access

    func engine(for id: String) async throws -> MLEngine {
        return try await engine(for: id, computeUnits: .all)
    }

    /// Variant that lets callers pin a specific compute-units preference.
    /// If a cached engine exists with a different `loadedComputeUnits`, it is
    /// unloaded and recreated so the new preference takes effect.
    func engine(for id: String, computeUnits: ComputeUnitsPreference) async throws -> MLEngine {
        // 1) Hit the cache, or evict on compute-units mismatch.
        let cachedHit = lock.withLock { () -> MLEngine? in
            guard let cached = loaded[id] else { return nil }
            if cached.loadedComputeUnits == computeUnits { return cached }
            loaded.removeValue(forKey: id)
            return nil
        }
        if let cached = cachedHit { return cached }

        // Note: an evicted-but-cached engine that we just dropped from the
        // dictionary is unloaded below by whoever held the reference. The
        // explicit `cached.unload()` was racy with concurrent callers and is
        // not strictly needed — `MLEngine.deinit` runs unload itself.

        // 2) Resolve factory + descriptor.
        let (factory, descriptor): (MLEngineFactory, ModelDescriptorNative) = try lock.withLock {
            guard let f = factories[id], let d = descriptors[id] else {
                throw MLEngineError.modelNotFound(id)
            }
            return (f, d)
        }

        // 3) Refuse load when the asset isn't on disk yet.
        if descriptor.requiresDownload && !descriptor.isAvailable {
            throw MLEngineError.modelNotDownloaded(id)
        }

        // 4) Build + load OUTSIDE the lock (CoreML compile can take seconds).
        let engine = factory(descriptor)
        engine.setPreferredComputeUnits(computeUnits)
        try await engine.load()

        // 5) Publish.
        lock.withLock { loaded[id] = engine }
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
        let cachedHit = lock.withLock { () -> MLDetectorEngine? in
            guard let cached = loadedDetectors[id] else { return nil }
            if cached.loadedComputeUnits == computeUnits { return cached }
            loadedDetectors.removeValue(forKey: id)
            return nil
        }
        if let cached = cachedHit { return cached }

        let (factory, descriptor): (MLDetectorEngineFactory, ModelDescriptorNative) = try lock.withLock {
            guard let f = detectorFactories[id], let d = descriptors[id] else {
                throw MLEngineError.modelNotFound(id)
            }
            return (f, d)
        }

        if descriptor.requiresDownload && !descriptor.isAvailable {
            throw MLEngineError.modelNotDownloaded(id)
        }

        let engine = factory(descriptor)
        engine.setPreferredComputeUnits(computeUnits)
        try await engine.load()

        lock.withLock { loadedDetectors[id] = engine }
        return engine
    }

    /// Inspect-only: returns the compute-units the engine for `id` is
    /// currently loaded with, or `nil` if it isn't loaded yet. Does NOT
    /// trigger a load — used by the method-channel `getComputeUnits`
    /// diagnostic (Task #20).
    func currentComputeUnits(for id: String) -> ComputeUnitsPreference? {
        lock.withLock {
            if let engine = loaded[id]          { return engine.loadedComputeUnits }
            if let det    = loadedDetectors[id] { return det.loadedComputeUnits }
            return nil
        }
    }

    func unloadAll() {
        let (classifiers, detectors): ([MLEngine], [MLDetectorEngine]) = lock.withLock {
            let c = Array(loaded.values)
            let d = Array(loadedDetectors.values)
            loaded.removeAll()
            loadedDetectors.removeAll()
            return (c, d)
        }
        classifiers.forEach { $0.unload() }
        detectors.forEach   { $0.unload() }
    }

    /// Unload a specific model to free memory (e.g. before loading a different one)
    func unload(_ id: String) {
        let (cls, det) = lock.withLock {
            (loaded.removeValue(forKey: id), loadedDetectors.removeValue(forKey: id))
        }
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
        let nudenetDefaultUrl = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/NudeNetDetector.mlmodelc.zip"
        let nudenet = ModelDescriptorNative(
            id:                 ModelIds.nudenet,
            displayName:        "NudeNet (Detection)",
            description:        "Body-part bounding-box detector (YOLOv8m, 640). ~46 MB download.",
            version:            "1.0",
            bundleResourceName: "NudeNetDetector",
            metadata: [
                "inputSize": 640,
                "framework": "CoreML",
                "kind":      "detector",
            ],
            downloadUrl:        UserDefaults.standard.string(forKey: "nsfw_model_url_\(ModelIds.nudenet)") ?? nudenetDefaultUrl,
            downloadSizeBytes:  48_000_000
        )
        register(detectorDescriptor: nudenet) { CoreMLDetectorEngine(descriptor: $0) }
    }

    // MARK: - Dynamic URL configuration

    /// Set the download URL for a model at runtime (persisted via UserDefaults).
    /// Call this before the model is needed.
    func setModelDownloadUrl(_ url: String, for modelId: String) {
        UserDefaults.standard.set(url, forKey: "nsfw_model_url_\(modelId)")
        // Re-register with updated URL.
        let original = lock.withLock { descriptors[modelId] }
        guard let desc = original else { return }
        let updated = ModelDescriptorNative(
            id: desc.id,
            displayName: desc.displayName,
            description: desc.description,
            version: desc.version,
            bundleResourceName: desc.bundleResourceName,
            metadata: desc.metadata,
            downloadUrl: url,
            downloadSizeBytes: desc.downloadSizeBytes,
            // Preserve the pinned hash across URL overrides. A mirror serving
            // identical bytes still verifies; a mirror serving different
            // bytes is exactly the case we want to catch. Callers that
            // intentionally substitute the hash should re-register.
            expectedSha256: desc.expectedSha256
        )
        lock.withLock { descriptors[modelId] = updated }
    }
}
