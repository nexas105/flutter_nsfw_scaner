package com.example.nsfw_detect_ios.ml

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

typealias MLEngineFactory = (ModelDescriptorNative) -> MLEngine
typealias MLDetectorEngineFactory = (ModelDescriptorNative) -> MLDetectorEngine

/**
 * Distinguishes classifier ([MLEngine]) and detector ([MLDetectorEngine])
 * registrations. Pendant to iOS' `enum ModelKind`.
 */
enum class ModelKind { CLASSIFIER, DETECTOR }

/**
 * Singleton registry of all known ML models. Pendant to
 * `ios/Classes/ml/ModelRegistry.swift`.
 *
 *  - Models are lazily loaded and cached until [unload] / [unloadAll].
 *  - Calling [engine] with a different `delegate` than the one cached evicts
 *    the old engine and rebuilds a fresh one — same semantics as iOS'
 *    compute-units mismatch path.
 *  - Per-model URLs can be overridden at runtime via [setModelDownloadUrl];
 *    the value is persisted in [SharedPreferences] under the key
 *    `nsfw_model_url_<id>`.
 */
class ModelRegistry private constructor(appContext: Context) {

    private val appContext: Context = appContext.applicationContext
    private val prefs: SharedPreferences =
        this.appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val descriptors = mutableMapOf<String, ModelDescriptorNative>()
    private val factories = mutableMapOf<String, MLEngineFactory>()
    private val detectorFactories = mutableMapOf<String, MLDetectorEngineFactory>()
    private val kinds = mutableMapOf<String, ModelKind>()
    private val loaded = mutableMapOf<String, MLEngine>()
    private val loadedDetectors = mutableMapOf<String, MLDetectorEngine>()

    /** Coroutine-friendly lock so suspending callers don't block a worker thread. */
    private val mutex = Mutex()

    init {
        registerBuiltins()
    }

    // MARK: - Registration

    fun register(descriptor: ModelDescriptorNative, factory: MLEngineFactory) {
        synchronized(this) {
            descriptors[descriptor.id] = descriptor
            factories[descriptor.id] = factory
            kinds[descriptor.id] = ModelKind.CLASSIFIER
        }
    }

    /**
     * Register an object-detection ([MLDetectorEngine]) model. The descriptor
     * SHOULD include `metadata["kind"] = "detector"` so the wire payload also
     * reflects the kind for Dart consumers; the registry-side [kinds] map is
     * the source of truth for routing.
     */
    fun registerDetector(descriptor: ModelDescriptorNative, factory: MLDetectorEngineFactory) {
        synchronized(this) {
            descriptors[descriptor.id] = descriptor
            detectorFactories[descriptor.id] = factory
            kinds[descriptor.id] = ModelKind.DETECTOR
        }
    }

    fun allDescriptors(): List<ModelDescriptorNative> = synchronized(this) {
        descriptors.values.toList()
    }

    fun descriptor(id: String): ModelDescriptorNative? = synchronized(this) {
        descriptors[id]
    }

    /** Whether [id] is registered as a classifier or detector. `null` if unknown. */
    fun kind(id: String): ModelKind? = synchronized(this) { kinds[id] }

    // MARK: - Access

    /**
     * Return a loaded engine for [id], creating it if necessary.
     *
     * @param delegate Preferred TFLite delegate ("gpu", "nnapi", null = CPU).
     *                 If a cached engine was loaded with a different delegate,
     *                 it is unloaded and rebuilt.
     */
    suspend fun engine(id: String, delegate: String? = null): MLEngine {
        // Fast path under coroutine mutex: cache hit + delegate match.
        mutex.withLock {
            val cached = loaded[id]
            if (cached != null) {
                if (cached.loadedDelegate == delegate) return cached
                // Mismatch — drop and rebuild.
                loaded.remove(id)
                cached.unload()
            }
        }

        val (descriptor, factory) = synchronized(this) {
            val d = descriptors[id] ?: throw MLEngineError.ModelNotFound(id)
            val f = factories[id] ?: throw MLEngineError.ModelNotFound(id)
            d to f
        }

        // Refuse to build an engine for a downloadable model that isn't on disk.
        if (descriptor.requiresDownload && !descriptor.isAvailable(appContext)) {
            throw MLEngineError.ModelNotDownloaded(id)
        }

        val engine = factory(descriptor)
        engine.setPreferredAcceleratorDelegate(delegate)
        engine.load()

        mutex.withLock { loaded[id] = engine }
        return engine
    }

    suspend fun preload(id: String) {
        if (kind(id) == ModelKind.DETECTOR) {
            detectorEngine(id)
        } else {
            engine(id)
        }
    }

    /**
     * Returns a loaded [MLDetectorEngine] for [id], creating it if necessary.
     * Mirrors [engine] semantics: caches by id and rebuilds on delegate change.
     */
    suspend fun detectorEngine(id: String, delegate: String? = null): MLDetectorEngine {
        mutex.withLock {
            val cached = loadedDetectors[id]
            if (cached != null) {
                if (cached.loadedDelegate == delegate) return cached
                loadedDetectors.remove(id)
                cached.unload()
            }
        }

        val (descriptor, factory) = synchronized(this) {
            val d = descriptors[id] ?: throw MLEngineError.ModelNotFound(id)
            val f = detectorFactories[id] ?: throw MLEngineError.ModelNotFound(id)
            d to f
        }

        if (descriptor.requiresDownload && !descriptor.isAvailable(appContext)) {
            throw MLEngineError.ModelNotDownloaded(id)
        }

        val engine = factory(descriptor)
        engine.setPreferredAcceleratorDelegate(delegate)
        engine.load()

        mutex.withLock { loadedDetectors[id] = engine }
        return engine
    }

    suspend fun unloadAll() {
        val classifiers: List<MLEngine>
        val detectors: List<MLDetectorEngine>
        mutex.withLock {
            classifiers = loaded.values.toList()
            detectors   = loadedDetectors.values.toList()
            loaded.clear()
            loadedDetectors.clear()
        }
        classifiers.forEach { it.unload() }
        detectors.forEach { it.unload() }
    }

    suspend fun unload(id: String) {
        val cls: MLEngine?
        val det: MLDetectorEngine?
        mutex.withLock {
            cls = loaded.remove(id)
            det = loadedDetectors.remove(id)
        }
        cls?.unload()
        det?.unload()
    }

    // MARK: - Dynamic URL configuration

    /**
     * Persist a runtime override URL for a downloadable model and refresh the
     * cached descriptor. Pendant to iOS' [UserDefaults] write.
     */
    fun setModelDownloadUrl(url: String, modelId: String) {
        prefs.edit().putString(prefsKey(modelId), url).apply()
        synchronized(this) {
            val current = descriptors[modelId] ?: return
            descriptors[modelId] = current.copy(downloadUrl = url)
        }
    }

    private fun prefsKey(modelId: String) = "nsfw_model_url_$modelId"

    private fun resolveDownloadUrl(modelId: String, default: String): String =
        prefs.getString(prefsKey(modelId), null) ?: default

    // MARK: - Builtins

    private fun registerBuiltins() {
        // ── Bundled (shipped inside the APK assets) ─────────────────────
        val openNsfw2 = ModelDescriptorNative(
            id = ModelIds.OPEN_NSFW_2,
            displayName = "OpenNSFW2 (Bundled)",
            description = "Lightweight NSFW classifier — 11 MB, fast, good baseline.",
            version = "1.0",
            // Logical resource name. TFLiteEngine maps this to the actual asset
            // file `open_nsfw2.tflite` shipped under android/src/main/assets/.
            bundleResourceName = "open_nsfw_2",
            metadata = mapOf(
                "inputSize" to 224,
                "outputSize" to 2,
                "framework" to "TFLite",
            ),
        )
        register(openNsfw2) { TFLiteEngine(appContext, it) }

        // ── Downloadable (.tflite.zip on GitHub Release) ────────────────
        // The TFLite artefacts in models-v1 have ViT normalisation (2x - 1)
        // and softmax baked into the graph (see tools/convert_models.py),
        // so TFLiteEngine passes raw [0, 1] floats and reads [0, 1] probs
        // directly — symmetric to iOS via Vision + ClassifierConfig.
        val falconsaiDefault = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/FalconsaiNSFW.tflite.zip"
        val falconsai = ModelDescriptorNative(
            id = ModelIds.FALCONSAI,
            displayName = "Falconsai ViT NSFW",
            description = "High-accuracy ViT classifier (98%). ~75 MB download.",
            version = "1.0",
            bundleResourceName = "FalconsaiNSFW",
            metadata = mapOf(
                "inputSize" to 224,
                "outputSize" to 2,
                "framework" to "TFLite",
            ),
            downloadUrl = resolveDownloadUrl(ModelIds.FALCONSAI, falconsaiDefault),
            downloadSizeBytes = 78_000_000L,
        )
        register(falconsai) { TFLiteEngine(appContext, it) }

        val adamcoddDefault = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/AdamCoddNSFW.tflite.zip"
        val adamcodd = ModelDescriptorNative(
            id = ModelIds.ADAMCODD,
            displayName = "AdamCodd ViT NSFW",
            description = "Highest-accuracy ViT-384 detector (AUC 0.9948). ~75 MB download.",
            version = "1.0",
            bundleResourceName = "AdamCoddNSFW",
            metadata = mapOf(
                "inputSize" to 384,
                "outputSize" to 2,
                "framework" to "TFLite",
            ),
            downloadUrl = resolveDownloadUrl(ModelIds.ADAMCODD, adamcoddDefault),
            downloadSizeBytes = 78_000_000L,
        )
        register(adamcodd) { TFLiteEngine(appContext, it) }

        // ── Detector model: NudeNet (downloadable .tflite.zip) ──────────
        // The user hosts the converted artefact themselves. Default URL is a
        // placeholder following the existing release naming pattern.
        val nudenetDefault = "https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models/NudeNetDetector.tflite.zip"
        val nudenet = ModelDescriptorNative(
            id = ModelIds.NUDENET,
            displayName = "NudeNet (Detection)",
            description = "Body-part bounding-box detector. ~50 MB.",
            version = "1.0",
            bundleResourceName = "NudeNetDetector",
            metadata = mapOf(
                "inputSize" to 320,
                "framework" to "TFLite",
                "kind" to "detector",
            ),
            downloadUrl = resolveDownloadUrl(ModelIds.NUDENET, nudenetDefault),
            downloadSizeBytes = 50_000_000L,
        )
        registerDetector(nudenet) { TFLiteDetectorEngine(appContext, it) }
    }

    companion object {
        private const val PREFS_NAME = "nsfw_detect_model_registry"

        @Volatile
        private var INSTANCE: ModelRegistry? = null

        fun getInstance(context: Context): ModelRegistry {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: ModelRegistry(context).also { INSTANCE = it }
            }
        }
    }
}
