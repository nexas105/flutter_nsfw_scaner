import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io' show File, HttpClient, HttpException;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart'
    show ImageConfiguration, ImageProvider, ImageStream, ImageStreamListener;
import 'body_part_detection.dart';
import 'ensemble_strategy.dart';
import 'frame_stream_scanner.dart';
import 'media_item.dart';
import 'model_registration.dart';
import 'redaction_mode.dart';
import 'model_download_progress.dart';
import 'nsfw_init_options.dart';
import 'nsfw_model_manager.dart';
import 'perceptual_cache.dart';
import 'picked_media.dart';
import 'scan_configuration.dart';
import 'scan_region.dart';
import 'scan_result.dart';
import 'scan_session.dart';
import 'camera_configuration.dart';
import 'camera_scan_session.dart';
import 'model_descriptor.dart';
import 'permissions/permission_kind.dart';
import '../platform/nsfw_platform_interface.dart';
import '../platform/nsfw_method_channel.dart';

/// Main entry point for on-device NSFW scanning.
///
/// Use [NsfwDetector.instance] to request permissions, inspect available
/// models, scan the photo library, classify individual files or byte buffers,
/// and start live camera scanning. Classification runs through the platform
/// implementation and is intended to keep media processing on the device; do
/// not treat the resulting labels as proof that content is safe or unsafe.
///
/// Results are probabilistic model outputs. Tune thresholds for your product,
/// provide appropriate user controls, and expect false positives and false
/// negatives.
class NsfwDetector {
  NsfwDetector._() {
    // Auto-register the method channel implementation on first access
    // (can be overridden in tests by setting NsfwPlatformInterface.instance manually)
    if (NsfwPlatformInterface.instance is NsfwUninitializedPlatform) {
      NsfwPlatformInterface.instance = NsfwMethodChannel();
    }
  }

  static final NsfwDetector instance = NsfwDetector._();

  NsfwPlatformInterface get _platform => NsfwPlatformInterface.instance;

  StreamController<ModelDownloadProgress>? _downloadProgressController;
  StreamSubscription<Map<dynamic, dynamic>>? _downloadProgressSub;
  // Latest in-flight progress event per modelId. Cleared when a download
  // emits `isComplete` so the next subscriber doesn't replay stale state.
  final Map<String, ModelDownloadProgress> _lastDownloadProgress = {};

  NsfwModelManager? _models;
  Future<NsfwInitReport>? _initFuture;
  double _defaultThreshold = 0.7;

  PerceptualCache? _perceptualCache;
  CropResistantCache? _cropResistantCache;

  /// Lazily-initialised in-memory [CropResistantCache].
  ///
  /// Uses [BlockPerceptualHash] (16-block grid by default) so cropped
  /// re-uploads still match the original entry. Roughly 16x slower per
  /// lookup than [perceptualCache] — prefer it for forwarded-image
  /// moderation pipelines, fall back to [perceptualCache] when raw speed
  /// matters more than crop resistance.
  CropResistantCache get cropResistantCache =>
      _cropResistantCache ??= CropResistantCache();

  /// Lazily-initialised in-memory [PerceptualCache].
  ///
  /// Use as a pre-check before [scanBytes] to skip duplicate / near-duplicate
  /// inputs:
  ///
  /// ```dart
  /// final cache = NsfwDetector.instance.perceptualCache;
  /// final cached = await cache.lookup(bytes);
  /// if (cached != null) return cached;
  /// final result = await NsfwDetector.instance.scanBytes(bytes);
  /// await cache.remember(bytes, result);
  /// ```
  ///
  /// The cache is opt-in — the detector itself does not call it. Capacity
  /// defaults to 256 entries; rebuild with `PerceptualCache(capacity: …)` if
  /// you need a different size.
  PerceptualCache get perceptualCache =>
      _perceptualCache ??= PerceptualCache();

  /// High-level model lifecycle facade — preload, download, ensureReady,
  /// state-change stream. Lazily constructed on first access.
  NsfwModelManager get models =>
      _models ??= NsfwModelManager(_platform, downloadProgress);

  /// True once [init] has resolved at least once.
  bool get isInitialized => _initFuture != null;

  /// App-wide default confidence threshold. Set via [NsfwInitOptions.defaultThreshold]
  /// when calling [init]. Scan APIs still accept per-call overrides.
  double get defaultThreshold => _defaultThreshold;

  /// Initialises the plugin once and warms up models. Idempotent — repeated
  /// calls return the same in-flight or completed report.
  ///
  /// Subsequent calls with *different* options are a no-op; use [reinit] to
  /// reconfigure (e.g. swap models, toggle logging, change threshold).
  ///
  /// Use as the canonical startup hook:
  ///
  /// ```dart
  /// await NsfwDetector.instance.init(NsfwInitOptions(
  ///   preloadModels: [ModelIds.openNsfw2],
  ///   downloadIfMissing: [ModelIds.openNsfw2],
  ///   enableNativeLogging: kDebugMode,
  /// ));
  /// ```
  ///
  /// If [init] is never called, the plugin lazy-initialises on first use.
  Future<NsfwInitReport> init([
    NsfwInitOptions options = const NsfwInitOptions(),
  ]) {
    final existing = _initFuture;
    if (existing != null) return existing;
    return _initFuture = _runInit(options);
  }

  /// Forces a fresh init pass with [options]. Use this when you need to
  /// reconfigure after the first [init] (e.g. toggle native logging at
  /// runtime, swap preloaded models). Awaits any in-flight init before
  /// starting the new pass to avoid races.
  Future<NsfwInitReport> reinit([
    NsfwInitOptions options = const NsfwInitOptions(),
  ]) async {
    final existing = _initFuture;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {/* swallow — we're about to retry */}
    }
    return _initFuture = _runInit(options);
  }

  Future<NsfwInitReport> _runInit(NsfwInitOptions options) async {
    final stopwatch = Stopwatch()..start();
    _defaultThreshold = options.defaultThreshold;

    final preloaded = <String>[];
    final downloaded = <String>[];
    final errors = <String, String>{};

    // Toggle logging in both directions so reinit() with the opposite value
    // actually flips the native flag. Wrapped because some test platforms
    // don't implement setLogging at all.
    try {
      await _platform.setLogging(options.enableNativeLogging);
    } catch (e) {
      errors['__logging__'] = e.toString();
    }

    try {
      for (final id in options.downloadIfMissing) {
        try {
          await models.ensureReady(id);
          downloaded.add(id);
        } catch (e) {
          errors[id] = e.toString();
          if (!options.tolerateModelErrors) {
            throw StateError('Model "$id" failed to ensure-ready: $e');
          }
        }
      }

      for (final id in options.preloadModels) {
        if (downloaded.contains(id)) continue; // already preloaded by ensureReady
        try {
          await models.preload(id);
          preloaded.add(id);
        } catch (e) {
          errors[id] = e.toString();
          if (!options.tolerateModelErrors) {
            throw StateError('Model "$id" failed to preload: $e');
          }
        }
      }
    } catch (e) {
      // tolerateModelErrors == false → re-throw, but clear the cached future
      // so the caller can fix the env and call init() again.
      _initFuture = null;
      rethrow;
    } finally {
      stopwatch.stop();
    }

    return NsfwInitReport(
      preloaded: preloaded,
      downloaded: downloaded,
      errors: errors,
      elapsed: stopwatch.elapsed,
    );
  }

  /// Broadcast stream of model-download progress events emitted while a
  /// download is in flight. The stream multiplexes events from any concurrent
  /// downloads — discriminate via [ModelDownloadProgress.modelId].
  ///
  /// Late subscribers receive a replay of the latest cached in-flight event
  /// per `modelId` immediately on subscribe — so attaching a listener after a
  /// download has already started still gets the most recent fraction (no
  /// race window where the UI shows 0% until the next native event lands).
  /// The cache is cleared on `isComplete` so completed downloads aren't
  /// replayed to future subscribers.
  ///
  /// The stream is lazy: it subscribes to the native event stream only when
  /// the first listener attaches. Cancel listeners when you no longer need
  /// updates so the underlying subscription can be torn down.
  Stream<ModelDownloadProgress> get downloadProgress {
    _ensureDownloadProgressController();
    final controller = _downloadProgressController!;
    return _replayDownloadProgress(controller.stream);
  }

  void _ensureDownloadProgressController() {
    final existing = _downloadProgressController;
    if (existing != null && !existing.isClosed) return;
    StreamController<ModelDownloadProgress>? controller;
    controller = StreamController<ModelDownloadProgress>.broadcast(
      onCancel: () {
        // Only tear down the native subscription when the controller has no
        // listeners left. Otherwise we'd cancel mid-download for other
        // subscribers.
        if (controller?.hasListener == false) {
          _downloadProgressSub?.cancel();
          _downloadProgressSub = null;
        }
      },
    );
    _downloadProgressController = controller;
    _downloadProgressSub = _platform.scanEventStream.listen(
      (event) {
        if (event['type'] == 'modelDownloadProgress') {
          final progress = ModelDownloadProgress.fromMap(event);
          if (progress.isComplete || progress.error != null) {
            _lastDownloadProgress.remove(progress.modelId);
          } else {
            _lastDownloadProgress[progress.modelId] = progress;
          }
          if (!controller!.isClosed) controller.add(progress);
        }
      },
      onError: (_) {/* swallow — native scan errors aren't download errors */},
    );
  }

  /// Wraps [source] in a per-listener stream that synchronously emits the
  /// last cached in-flight progress event(s) before forwarding live events.
  Stream<ModelDownloadProgress> _replayDownloadProgress(
    Stream<ModelDownloadProgress> source,
  ) {
    late StreamController<ModelDownloadProgress> out;
    StreamSubscription<ModelDownloadProgress>? sub;
    out = StreamController<ModelDownloadProgress>(
      onListen: () {
        // Replay any in-flight progress synchronously so late subscribers
        // don't see a 0% gap.
        for (final cached in _lastDownloadProgress.values) {
          out.add(cached);
        }
        sub = source.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  /// Requests access to the user's photo library.
  ///
  /// A limited-library grant may still allow scanning of selected assets.
  Future<PhotoLibraryPermissionStatus> requestPermission() =>
      _platform.requestPermission();

  /// Returns the current photo-library permission status without prompting.
  Future<PhotoLibraryPermissionStatus> checkPermission() =>
      _platform.checkPermission();

  /// Returns the current camera-permission status.
  ///
  /// Falls back to [PermissionStatus.notDetermined] when the platform
  /// implementation does not yet support it (pre–Phase-2 / pre–Phase-3 native
  /// handlers). This lets [NsfwPermissionsView] render a Camera row today
  /// without forcing the camera-pipeline phases to land first.
  Future<PermissionStatus> checkCameraPermission() async {
    try {
      return await _platform.checkCameraPermission();
    } on UnimplementedError {
      return PermissionStatus.notDetermined;
    }
  }

  /// Requests camera permission. Same graceful fallback as
  /// [checkCameraPermission] when the native side hasn't been wired yet.
  Future<PermissionStatus> requestCameraPermission() async {
    try {
      return await _platform.requestCameraPermission();
    } on UnimplementedError {
      return PermissionStatus.notDetermined;
    }
  }

  /// Returns the NSFW models registered by the native platform side.
  Future<List<ModelDescriptor>> availableModels() =>
      _platform.availableModels();

  /// Downloads or loads [modelId] ahead of a scan when the platform supports
  /// explicit preloading.
  Future<void> preloadModel(String modelId) => _platform.preloadModel(modelId);

  /// Starts a photo-library scan using [config].
  ///
  /// The returned [ScanSession] streams [ScanResult] values and progress. Media
  /// is classified on the device through the native implementation; results are
  /// confidence scores rather than guarantees.
  Future<ScanSession> startScan(ScanConfiguration config) =>
      ScanSession.start(config: config, platform: _platform);

  /// Clears native scan state for the current library scan.
  Future<void> resetScan() => _platform.resetScan();

  /// Downloads a model by [modelId].
  ///
  /// Listen to [downloadProgress] for progress events when the platform emits
  /// them. Returns whether the platform reports the download as successful.
  Future<bool> downloadModel(String modelId, {String? url}) =>
      _platform.downloadModel(modelId, url: url);

  /// Convenience over [downloadModel] + [downloadProgress]: kicks off the
  /// download and resolves once it completes. [onProgress] is invoked for
  /// every progress event in the meantime.
  ///
  /// Throws [StateError] if the native side rejects the download or emits an
  /// error event.
  Future<void> downloadModelWithProgress(
    String modelId, {
    String? url,
    void Function(ModelDownloadProgress progress)? onProgress,
  }) async {
    final completer = Completer<void>();
    late StreamSubscription<ModelDownloadProgress> sub;
    sub = downloadProgress.where((p) => p.modelId == modelId).listen(
      (p) {
        onProgress?.call(p);
        if (p.error != null && !completer.isCompleted) {
          completer.completeError(StateError(p.error!));
        } else if (p.isComplete && !completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    try {
      final ok = await _platform.downloadModel(modelId, url: url);
      if (!ok && !completer.isCompleted) {
        completer.completeError(
            StateError('downloadModel($modelId) was rejected by the platform'));
      }
      await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  /// Deletes the locally stored copy of [modelId], if present.
  Future<void> deleteModel(String modelId) => _platform.deleteModel(modelId);

  /// Overrides the download URL used for [modelId].
  Future<void> setModelUrl(String modelId, String url) =>
      _platform.setModelUrl(modelId, url);

  /// Enable or disable native logging (visible in Flutter console via `print`).
  /// Call early, e.g. `NsfwDetector.instance.setLogging(true)` before scanning.
  Future<void> setLogging(bool enabled) => _platform.setLogging(enabled);

  /// Clears the persistent scan-result cache used by `skipAlreadyScanned`.
  /// Pass [modelId] to drop only that model's entries; omit to clear everything.
  /// After clearing, the next scan re-classifies all matching assets.
  Future<void> clearScanCache({String? modelId}) =>
      _platform.clearScanCache(modelId: modelId);

  // Active camera session — at most one at a time.
  CameraScanSession? _cameraSession;

  /// Starts the live camera scan.
  ///
  /// Throws [StateError] if a camera session is already running.
  /// Results stream via [CameraScanSession.results].
  Future<CameraScanSession> startCameraScan(
      [CameraConfiguration? config]) async {
    if (_cameraSession != null && _cameraSession!.isRunning) {
      throw StateError('A camera scan is already running.');
    }
    final cfg = config ?? const CameraConfiguration();
    final session =
        await CameraScanSession.start(config: cfg, platform: _platform);
    _cameraSession = session;
    return session;
  }

  /// Builds a [FrameStreamScanner] over [frames] — a generic adapter for
  /// WebRTC tracks, RTSP/HLS frame producers, or any custom source emitting
  /// encoded image buffers.
  ///
  /// See [FrameStreamScanner] for backpressure semantics and a
  /// `flutter_webrtc` integration example.
  ///
  /// ```dart
  /// final scanner = NsfwDetector.instance.scanFrameStream(
  ///   frames: myFrameStream,
  ///   targetFps: 2,
  ///   earlyExitOnNsfw: true,
  ///   dedupeCache: NsfwDetector.instance.perceptualCache,
  /// );
  /// scanner.results.listen((r) => print('frame: ${r.topCategory}'));
  /// ```
  FrameStreamScanner scanFrameStream({
    required Stream<Uint8List> frames,
    double? confidenceThreshold,
    int targetFps = 2,
    bool earlyExitOnNsfw = false,
    String? modelId,
    PerceptualCache? dedupeCache,
  }) {
    return FrameStreamScanner(
      frames: frames,
      confidenceThreshold: confidenceThreshold ?? _defaultThreshold,
      targetFps: targetFps,
      earlyExitOnNsfw: earlyExitOnNsfw,
      modelId: modelId,
      dedupeCache: dedupeCache,
    );
  }

  /// Stops the active camera scan. No-op if none is running.
  Future<void> stopCameraScan() async {
    if (_cameraSession != null && _cameraSession!.isRunning) {
      await _cameraSession!.stop();
      _cameraSession = null;
    }
  }

  /// Resolves the effective threshold for a scan call, honouring any in-flight
  /// init so [_defaultThreshold] reflects the post-init value rather than the
  /// pre-init field.
  ///
  /// Captures the result locally so callers can use it across async gaps
  /// without worrying about a parallel `reinit` flipping the field underneath.
  Future<double> _resolveThreshold(double? override) async {
    if (override != null) {
      if (!override.isFinite || override < 0.0 || override > 1.0) {
        throw ArgumentError.value(
          override,
          'confidenceThreshold',
          'must be a finite value in [0.0, 1.0]',
        );
      }
      return override;
    }
    // Await in-flight init so default-threshold reads after any pending
    // reconfiguration. Errors are swallowed; the field already has a safe
    // fallback (0.7).
    final pending = _initFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {/* ignored — the threshold default is still safe */}
    }
    return _defaultThreshold;
  }

  /// Scans a single photo-library asset by local identifier.
  ///
  /// [confidenceThreshold] is copied into the returned [ScanResult] and affects
  /// convenience getters such as `isNsfw`; the raw labels remain available.
  /// [region] restricts the scan to a normalised sub-rectangle of the asset.
  Future<ScanResult> scanAsset(
    String localIdentifier, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final t = await _resolveThreshold(confidenceThreshold);
    final map = await _platform.scanSingleAsset(
      localIdentifier,
      modelId: modelId,
      roi: region?.toJson(),
    );
    return ScanResult.fromMap(map, confidenceThreshold: t);
  }

  /// Shows the native photo/video picker, then scans the selected items.
  /// [maxItems] — max selectable items (0 = unlimited). Default: 1.
  /// Results stream via [ScanSession.results] exactly like [startScan].
  Future<ScanSession> pickAndScan({
    int maxItems = 1,
    ScanConfiguration? config,
  }) =>
      ScanSession.startPicker(
        config: config ?? const ScanConfiguration(),
        platform: _platform,
        maxItems: maxItems,
      );

  /// Scans an image from a local file path.
  ///
  /// The image is classified by the platform implementation. The returned
  /// [ScanResult] contains probabilistic labels sorted by NSFW priority and
  /// confidence. [region] restricts the scan to a normalised sub-rectangle.
  Future<ScanResult> scanFile(
    String filePath, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final t = await _resolveThreshold(confidenceThreshold);
    final map = await _platform.scanFilePath(
      filePath,
      modelId: modelId,
      roi: region?.toJson(),
    );
    return ScanResult.fromMap(map, confidenceThreshold: t);
  }

  /// Opens the native photo / video picker and returns the selected items
  /// without classifying them. Use the returned [PickedMedia.localId] with
  /// [scanAsset] to classify on demand, or with [startScan]
  /// (`ScanConfiguration.assetIdentifiers`) to scan a fixed subset.
  ///
  /// [type] filters what the picker shows. [multiple] toggles single vs.
  /// multi-selection; [maxItems] caps multi-selection (ignored when
  /// `multiple: false`; null on iOS = unlimited, on Android = unlimited).
  Future<List<PickedMedia>> pickMedia({
    MediaPickerType type = MediaPickerType.any,
    bool multiple = false,
    int? maxItems,
  }) async {
    final raw = await _platform.pickMedia(
      type: type.wireValue,
      multiple: multiple,
      maxItems: maxItems,
    );
    return raw.map(PickedMedia.fromMap).toList(growable: false);
  }

  /// Scans an image from raw bytes (JPEG, PNG, etc.).
  ///
  /// Use this for images already loaded by your app. Keep byte buffers small
  /// enough for the target devices. [region] restricts the scan to a
  /// normalised sub-rectangle.
  Future<ScanResult> scanBytes(
    Uint8List bytes, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final t = await _resolveThreshold(confidenceThreshold);
    final map = await _platform.scanImageBytes(
      bytes,
      modelId: modelId,
      roi: region?.toJson(),
    );
    return ScanResult.fromMap(map, confidenceThreshold: t);
  }

  /// Scans any Flutter [ImageProvider] — `NetworkImage`, `MemoryImage`,
  /// `FileImage`, `AssetImage`, or your own subclass.
  ///
  /// Resolves the provider, encodes the frame to PNG bytes once, then
  /// delegates to [scanBytes]. Useful when your UI already holds an
  /// `ImageProvider` (gallery tiles, chat bubbles, hero images) and you want
  /// to gate the same image you're about to render.
  ///
  /// [configuration] controls device-pixel-ratio / locale resolution of
  /// providers that branch on it (typically the default is fine).
  Future<ScanResult> scanImageProvider(
    ImageProvider provider, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
    ImageConfiguration configuration = ImageConfiguration.empty,
  }) async {
    final bytes = await _resolveImageProviderBytes(provider, configuration);
    return scanBytes(
      bytes,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
      region: region,
    );
  }

  /// Fetches a remote image over HTTP/HTTPS and scans the response body.
  ///
  /// Convenience wrapper for chat / messaging / link-preview flows that want
  /// to gate a URL before rendering. Streams the response with a hard byte
  /// cap ([maxBytes], default 32 MB) so a malicious server can't OOM the
  /// caller.
  ///
  /// Throws [ArgumentError] for non-http(s) schemes, [HttpException] on a
  /// non-2xx response, [TimeoutException] when [timeout] elapses, and
  /// [StateError] when the payload exceeds [maxBytes].
  Future<ScanResult> scanUrl(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw ArgumentError.value(
        url,
        'url',
        'only http and https schemes are supported',
      );
    }
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(url).timeout(timeout);
      headers?.forEach((k, v) => req.headers.add(k, v));
      final response = await req.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} fetching $url',
          uri: url,
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw StateError(
            'Remote payload exceeds $maxBytes bytes for $url — aborting',
          );
        }
      }
      return scanBytes(
        builder.takeBytes(),
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Fan an input out to every model in [strategy.modelIds], then combine
  /// the per-model results via the strategy.
  ///
  /// Inference cost scales linearly with the model count — default is OFF;
  /// only enable when the false-positive reduction from voting is worth
  /// the 2-3× latency.
  ///
  /// Currently classifier-only. Passing a detector model id throws
  /// `ArgumentError` after the first per-model scan returns detections —
  /// detector outputs are spatial and not meaningfully averageable.
  Future<ScanResult> scanBytesEnsemble(
    Uint8List bytes,
    EnsembleStrategy strategy, {
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final perModel = <ScanResult>[];
    for (final modelId in strategy.modelIds) {
      final r = await scanBytes(
        bytes,
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
      if (r.hasDetections) {
        throw ArgumentError(
          'Ensembles are classifier-only — modelId "$modelId" returned a '
          'detector result. Drop detector ids from EnsembleStrategy.modelIds.',
        );
      }
      perModel.add(r);
    }
    return strategy.combine(perModel);
  }

  /// File-input variant of [scanBytesEnsemble]. See that method for the
  /// per-strategy semantics and cost notes.
  Future<ScanResult> scanFileEnsemble(
    String filePath,
    EnsembleStrategy strategy, {
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final perModel = <ScanResult>[];
    for (final modelId in strategy.modelIds) {
      final r = await scanFile(
        filePath,
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
      if (r.hasDetections) {
        throw ArgumentError(
          'Ensembles are classifier-only — modelId "$modelId" returned a '
          'detector result. Drop detector ids from EnsembleStrategy.modelIds.',
        );
      }
      perModel.add(r);
    }
    return strategy.combine(perModel);
  }

  /// Asset-input variant of [scanBytesEnsemble].
  Future<ScanResult> scanAssetEnsemble(
    String localIdentifier,
    EnsembleStrategy strategy, {
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final perModel = <ScanResult>[];
    for (final modelId in strategy.modelIds) {
      final r = await scanAsset(
        localIdentifier,
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
      if (r.hasDetections) {
        throw ArgumentError(
          'Ensembles are classifier-only — modelId "$modelId" returned a '
          'detector result. Drop detector ids from EnsembleStrategy.modelIds.',
        );
      }
      perModel.add(r);
    }
    return strategy.combine(perModel);
  }

  /// Register a custom ML model at runtime so its [registration.id] can be
  /// used with any of the scan APIs (`modelId:` parameter,
  /// `ScanConfiguration.modelId`, `NsfwInitOptions.preloadModels`).
  ///
  /// Registrations live for the process lifetime only — re-register on cold
  /// start. The native side resolves [registration.assetPath] against the
  /// host app's sandboxed writable directories (iOS Application Support /
  /// Documents / Caches; Android `filesDir` / `cacheDir`) and rejects paths
  /// that escape the sandbox.
  ///
  /// Returns the absolute resolved path the engine will load from — useful
  /// for diagnostics. Throws on invalid path / duplicate id / missing
  /// artefact.
  ///
  /// ```dart
  /// final tflitePath = '${(await getApplicationSupportDirectory()).path}/my_model.tflite';
  /// // ...copy the model bytes there...
  /// await NsfwDetector.instance.registerModel(ModelRegistration(
  ///   id: 'my_custom_model',
  ///   displayName: 'My fine-tuned NSFW',
  ///   assetPath: tflitePath,
  ///   inputSize: 224,
  /// ));
  /// final result = await NsfwDetector.instance.scanFile(
  ///   '/path/to/image.jpg',
  ///   modelId: 'my_custom_model',
  /// );
  /// ```
  Future<String> registerModel(ModelRegistration registration) =>
      _platform.registerModel(registration.toChannelMap());

  /// Signals the native scan loop to skip the next asset it would process.
  ///
  /// Best-effort, fire-and-forget: one outstanding skip is consumed by the
  /// next per-asset task that checks the flag. Multiple `skipCurrentAsset`
  /// calls in quick succession collapse to a single skip — use
  /// [cancelScan] if you want to abandon the rest of the session entirely.
  ///
  /// No effect when no scan is running.
  Future<void> skipCurrentAsset() => _platform.skipCurrentAsset();

  /// Looks up a previously-scanned result from the on-device cache without
  /// triggering a new classification. Returns `null` if the cache has no
  /// entry for the given identifier.
  ///
  /// The returned [ScanResult] is marked with `fromCache = true`. Note that
  /// the cache does not invalidate on asset edits — if you need
  /// freshness-aware semantics, re-scan and compare against the returned
  /// `scannedAt` timestamp yourself.
  Future<ScanResult?> cachedResult(
    String localIdentifier, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final map = await _platform.cachedResult(
      localIdentifier,
      modelId: modelId,
    );
    if (map == null) return null;
    final t = await _resolveThreshold(confidenceThreshold);
    return ScanResult.fromMap(map, confidenceThreshold: t);
  }

  /// Stream of [ScanResult] objects derived from the native scan event
  /// channel — every completed per-asset result (library scans, pickAndScan)
  /// surfaces here, so apps can subscribe once and update gallery badges
  /// without polling the cache themselves.
  ///
  /// Each subscription gets a fresh underlying stream. Cancel the
  /// subscription when done to free the channel.
  Stream<ScanResult> get cacheUpdates {
    return _platform.scanEventStream
        .where((event) => event['type'] == 'result')
        .map((event) => ScanResult.fromMap(
              event,
              confidenceThreshold: _defaultThreshold,
            ));
  }

  /// Pre-warms native asset decoding for the given identifiers so subsequent
  /// [scanAsset] or [startScan] calls hit warm I/O paths. On iOS this seeds
  /// `PHCachingImageManager`; on Android it touches the MediaStore thumbnail
  /// cache. Safe to call with a large list — the native side bounds the
  /// number of in-flight prefetches.
  ///
  /// Best-effort: silently no-ops on platforms without a warm-cache impl.
  Future<void> prefetchAssets(
    List<String> localIdentifiers, {
    String? modelId,
  }) {
    return _platform.prefetchAssets(localIdentifiers, modelId: modelId);
  }

  /// Returns a redacted copy of [bytes]. Detection-mode scans yield per-box
  /// redactions; classifier-only scans (no detections) fall back to redacting
  /// the entire image.
  ///
  /// [intensity] is clamped to `[0.0, 1.0]`. [outputFormat] defaults to
  /// `"jpeg"` (smaller) — pass `"png"` for lossless output. Throws when the
  /// native side fails to decode / encode.
  Future<Uint8List> redactBytes(
    Uint8List bytes,
    ScanResult result, {
    RedactionMode mode = RedactionMode.blur,
    double intensity = 1.0,
    String outputFormat = 'jpeg',
  }) {
    return _platform.redactBytes(
      bytes: bytes,
      detections: _detectionsToWire(result.detections),
      mode: mode.wireValue,
      intensity: intensity.clamp(0.0, 1.0).toDouble(),
      outputFormat: outputFormat,
    );
  }

  /// Redacts the image file at [inputPath] and writes the redacted copy to
  /// [outputPath] (or a sibling temp file when omitted). Returns the on-disk
  /// path of the redacted output as a [File].
  Future<File> redactFile(
    File input,
    ScanResult result, {
    File? outputFile,
    RedactionMode mode = RedactionMode.blur,
    double intensity = 1.0,
  }) async {
    final outPath = await _platform.redactFile(
      inputPath: input.path,
      detections: _detectionsToWire(result.detections),
      mode: mode.wireValue,
      intensity: intensity.clamp(0.0, 1.0).toDouble(),
      outputPath: outputFile?.path,
    );
    return File(outPath);
  }

  /// Convert Dart detections back to wire-shape maps for the channel call.
  /// Mirrors the native handlers' decoding contract — `box` is normalised
  /// `{x, y, width, height}` in `[0, 1]`.
  static List<Map<String, Object?>> _detectionsToWire(
    List<BodyPartDetection>? detections,
  ) {
    if (detections == null) return const [];
    return detections.map((d) => d.toMap()).cast<Map<String, Object?>>().toList(
          growable: false,
        );
  }

  /// Resolves an [ImageProvider] to PNG bytes via the Flutter image pipeline.
  /// Listener removal happens once (success OR error) — leaking the listener
  /// would keep the provider alive after the scan returns.
  static Future<Uint8List> _resolveImageProviderBytes(
    ImageProvider provider,
    ImageConfiguration configuration,
  ) {
    final completer = Completer<Uint8List>();
    final ImageStream stream = provider.resolve(configuration);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) async {
        stream.removeListener(listener);
        try {
          final data =
              await info.image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) {
            completer.completeError(
              StateError('ImageProvider produced no encodable bytes'),
            );
            return;
          }
          if (!completer.isCompleted) {
            completer.complete(data.buffer.asUint8List());
          }
        } finally {
          info.image.dispose();
        }
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// Scan a heterogeneous list of locations in one call.
  ///
  /// Each entry is routed by prefix:
  ///
  ///  * `file://`           → [scanFile]
  ///  * `http://` / `https://` → [scanUrl]
  ///  * `data:`             → base64-decoded then [scanBytes]
  ///  * anything else       → treated as a photo-library localIdentifier and
  ///                          forwarded to [scanAsset]
  ///
  /// Per-item failures surface as a [ScanResult.failed] entry so the batch
  /// always completes. Order is preserved. [onProgress] fires once per item
  /// with `(done, total)` counts.
  Future<List<ScanResult>> scanPaths(
    Iterable<String> paths, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
    void Function(int done, int total)? onProgress,
  }) async {
    final list = paths.toList(growable: false);
    final out = <ScanResult>[];
    for (var i = 0; i < list.length; i++) {
      final p = list[i];
      try {
        out.add(await _routePath(
          p,
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          region: region,
        ));
      } catch (e) {
        out.add(ScanResult.failed(
          localIdentifier: p,
          errorMessage: e.toString(),
        ));
      }
      onProgress?.call(out.length, list.length);
    }
    return out;
  }

  Future<ScanResult> _routePath(
    String p, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) {
    if (p.startsWith('file://')) {
      return scanFile(
        Uri.parse(p).toFilePath(),
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
    }
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return scanUrl(
        Uri.parse(p),
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
    }
    if (p.startsWith('data:')) {
      final comma = p.indexOf(',');
      if (comma == -1) {
        throw FormatException('Invalid data URI: missing comma', p);
      }
      final payload = p.substring(comma + 1);
      return scanBytes(
        base64Decode(payload),
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
        region: region,
      );
    }
    return scanAsset(
      p,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
      region: region,
    );
  }

  /// Group perceptually-identical media items into clusters using a dHash.
  ///
  /// Each item's bytes are hashed once (via [loadBytes]) then clustered by
  /// Hamming-distance threshold. Items that fail to load or hash are
  /// silently dropped. Singletons are NOT returned — only clusters of two
  /// or more.
  ///
  /// [loadBytes] decouples this from any particular storage layer — pass a
  /// closure that knows how to fetch the encoded bytes for each [MediaItem]
  /// (e.g. via `scanAsset` data, your CDN, the file system). Sequential to
  /// keep memory bounded; if you want parallelism, hash up front and call
  /// [PerceptualHash.hammingDistance] yourself.
  Future<List<List<MediaItem>>> findDuplicates(
    Iterable<MediaItem> items, {
    required Future<Uint8List?> Function(MediaItem item) loadBytes,
    int maxHammingDistance = 5,
  }) async {
    assert(maxHammingDistance >= 0 && maxHammingDistance <= 64);
    final hashed = <_HashedItem>[];
    for (final item in items) {
      final bytes = await loadBytes(item);
      if (bytes == null) continue;
      final hash = await PerceptualHash.compute(bytes);
      if (hash == null) continue;
      hashed.add(_HashedItem(item, hash));
    }
    // Greedy O(n²) clustering — n is typically small (<= a few hundred
    // gallery items per session). Compare against the first member of
    // each existing cluster; assign to the first match.
    final clusters = <List<_HashedItem>>[];
    for (final entry in hashed) {
      var added = false;
      for (final cluster in clusters) {
        if (entry.hash.hammingDistance(cluster.first.hash) <=
            maxHammingDistance) {
          cluster.add(entry);
          added = true;
          break;
        }
      }
      if (!added) clusters.add([entry]);
    }
    return clusters
        .where((c) => c.length >= 2)
        .map((c) => c.map((e) => e.item).toList(growable: false))
        .toList(growable: false);
  }

  /// Boolean shortcut over [scanFile] — returns whether the file crosses the
  /// NSFW threshold. Use this for simple gate checks where you don't need
  /// the full [ScanResult].
  Future<bool> isNsfwFile(
    String filePath, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final result = await scanFile(
      filePath,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
      region: region,
    );
    return result.isNsfw;
  }

  /// Boolean shortcut over [scanBytes] — returns whether the bytes cross the
  /// NSFW threshold.
  Future<bool> isNsfwBytes(
    Uint8List bytes, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final result = await scanBytes(
      bytes,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
      region: region,
    );
    return result.isNsfw;
  }

  /// Boolean shortcut over [scanAsset] — returns whether a photo-library
  /// asset crosses the NSFW threshold.
  Future<bool> isNsfwAsset(
    String localIdentifier, {
    String? modelId,
    double? confidenceThreshold,
    ScanRegion? region,
  }) async {
    final result = await scanAsset(
      localIdentifier,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
      region: region,
    );
    return result.isNsfw;
  }

  /// Requests photo-library permission and, if granted (including limited
  /// access), starts a scan. Returns `null` when the user denies / restricts
  /// access — callers should then surface their permission UI.
  Future<ScanSession?> requestPermissionAndStartScan(
    ScanConfiguration config,
  ) async {
    final status = await requestPermission();
    if (!status.canScan) return null;
    return startScan(config);
  }

  /// Scans every file path in [paths] sequentially. Returns the results in
  /// the same order. [onProgress] is invoked with `(completed, total)` after
  /// each item — handy for progress UIs without subscribing to a [ScanSession].
  ///
  /// Items that throw are returned as a failed [ScanResult] so the batch
  /// completes; inspect [ScanResult.status] / [ScanResult.errorMessage] for
  /// per-item errors.
  Future<List<ScanResult>> scanFiles(
    List<String> paths, {
    String? modelId,
    double? confidenceThreshold,
    void Function(int completed, int total)? onProgress,
  }) async {
    // Resolve once so the per-item threshold can't drift if reinit lands
    // mid-batch.
    final t = await _resolveThreshold(confidenceThreshold);
    return _scanBatch<String>(
      paths,
      (p) => scanFile(p, modelId: modelId, confidenceThreshold: t),
      onProgress: onProgress,
      confidenceThreshold: t,
      identifierFor: (p) => p,
    );
  }

  /// Scans every byte buffer in [items] sequentially. See [scanFiles] for
  /// progress and error semantics.
  Future<List<ScanResult>> scanAllBytes(
    List<Uint8List> items, {
    String? modelId,
    double? confidenceThreshold,
    void Function(int completed, int total)? onProgress,
  }) async {
    final t = await _resolveThreshold(confidenceThreshold);
    return _scanBatch<Uint8List>(
      items,
      (b) => scanBytes(b, modelId: modelId, confidenceThreshold: t),
      onProgress: onProgress,
      confidenceThreshold: t,
      identifierFor: (_) => '',
    );
  }

  /// Scans every photo-library local identifier in [localIdentifiers]
  /// sequentially. See [scanFiles] for progress and error semantics.
  Future<List<ScanResult>> scanAssets(
    List<String> localIdentifiers, {
    String? modelId,
    double? confidenceThreshold,
    void Function(int completed, int total)? onProgress,
  }) async {
    final t = await _resolveThreshold(confidenceThreshold);
    return _scanBatch<String>(
      localIdentifiers,
      (id) => scanAsset(id, modelId: modelId, confidenceThreshold: t),
      onProgress: onProgress,
      confidenceThreshold: t,
      identifierFor: (id) => id,
    );
  }

  Future<List<ScanResult>> _scanBatch<T>(
    List<T> items,
    Future<ScanResult> Function(T) scan, {
    required double confidenceThreshold,
    required String Function(T) identifierFor,
    void Function(int completed, int total)? onProgress,
  }) async {
    final results = <ScanResult>[];
    for (var i = 0; i < items.length; i++) {
      try {
        results.add(await scan(items[i]));
      } catch (e) {
        // Surface as a failed result so the batch completes deterministically.
        results.add(ScanResult.failed(
          localIdentifier: identifierFor(items[i]),
          errorMessage: e.toString(),
          confidenceThreshold: confidenceThreshold,
        ));
      }
      onProgress?.call(i + 1, items.length);
    }
    return results;
  }

  /// Preloads [modelId] (or the default model) so the first real scan is
  /// fast. Equivalent to [init] with `preloadModels: [modelId]`.
  ///
  /// Prefer [init] for the canonical bootstrap so logging, default
  /// threshold, and multi-model preload all flow through one call.
  Future<void> ready({String modelId = ModelIds.openNsfw2}) =>
      preloadModel(modelId);

  /// Sweeps NSFW confidence thresholds against [samples] to find the smallest
  /// threshold whose **precision** (`TP / (TP + FP)`) is at least
  /// [precisionTarget].
  ///
  /// Each sample is a tuple of image bytes + an `expectedNsfw` ground-truth
  /// label. The method runs [scanBytes] on every sample once, then sweeps
  /// candidate thresholds in `0.05` increments from `0.05` to `0.95`.
  ///
  /// Returns the chosen threshold. Throws [ArgumentError] when [samples] is
  /// empty. If no threshold meets the precision target, returns `1.0` —
  /// effectively never flagging anything (the safest possible cut-off).
  ///
  /// Pure Dart — no native changes needed.
  Future<double> calibrate({
    required List<({Uint8List bytes, bool expectedNsfw})> samples,
    double precisionTarget = 0.9,
    String? modelId,
  }) async {
    if (samples.isEmpty) {
      throw ArgumentError.value(samples, 'samples', 'must be non-empty');
    }
    assert(
      precisionTarget >= 0.0 && precisionTarget <= 1.0,
      'precisionTarget must be in [0.0, 1.0]',
    );

    // Run each sample once at a permissive threshold (0.0) so the raw
    // topConfidence + topCategory are stable; we re-bucket them per
    // candidate threshold without re-running the model.
    final scored =
        <({double topConfidence, bool topIsNsfw, bool expectedNsfw})>[];
    for (final s in samples) {
      final r = await scanBytes(
        s.bytes,
        modelId: modelId,
        confidenceThreshold: 0.0,
      );
      scored.add((
        topConfidence: r.topConfidence,
        topIsNsfw: r.topCategory.isNsfw,
        expectedNsfw: s.expectedNsfw,
      ));
    }

    double best = 1.0;
    for (var step = 1; step <= 19; step++) {
      final t = step * 0.05;
      var tp = 0;
      var fp = 0;
      for (final s in scored) {
        final predicted = s.topIsNsfw && s.topConfidence >= t;
        if (predicted && s.expectedNsfw) tp++;
        if (predicted && !s.expectedNsfw) fp++;
      }
      if (tp + fp == 0) continue;
      final precision = tp / (tp + fp);
      if (precision >= precisionTarget) {
        best = t;
        break;
      }
    }
    return best;
  }
}

/// Internal helper for [NsfwDetector.findDuplicates] — keeps the
/// `(item, hash)` pair together during clustering without exposing a tuple
/// type at the public API boundary.
class _HashedItem {
  _HashedItem(this.item, this.hash);
  final MediaItem item;
  final PerceptualHash hash;
}
