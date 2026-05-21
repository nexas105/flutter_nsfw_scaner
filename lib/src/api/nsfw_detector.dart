import 'dart:async';
import 'dart:typed_data';
import 'model_download_progress.dart';
import 'nsfw_init_options.dart';
import 'nsfw_model_manager.dart';
import 'picked_media.dart';
import 'scan_configuration.dart';
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

  NsfwModelManager? _models;
  Future<NsfwInitReport>? _initFuture;
  double _defaultThreshold = 0.7;

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
  /// The stream is lazy: it subscribes to the native event stream only when
  /// the first listener attaches. Cancel listeners when you no longer need
  /// updates so the underlying subscription can be torn down.
  Stream<ModelDownloadProgress> get downloadProgress {
    final existing = _downloadProgressController;
    if (existing != null && !existing.isClosed) return existing.stream;
    final controller = StreamController<ModelDownloadProgress>.broadcast(
      onCancel: () {
        _downloadProgressSub?.cancel();
        _downloadProgressSub = null;
      },
    );
    _downloadProgressController = controller;
    _downloadProgressSub = _platform.scanEventStream.listen(
      (event) {
        if (event['type'] == 'modelDownloadProgress') {
          if (!controller.isClosed) {
            controller.add(ModelDownloadProgress.fromMap(event));
          }
        }
      },
      onError: (_) {/* swallow — native scan errors aren't download errors */},
    );
    return controller.stream;
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

  /// Stops the active camera scan. No-op if none is running.
  Future<void> stopCameraScan() async {
    if (_cameraSession != null && _cameraSession!.isRunning) {
      await _cameraSession!.stop();
      _cameraSession = null;
    }
  }

  /// Scans a single photo-library asset by local identifier.
  ///
  /// [confidenceThreshold] is copied into the returned [ScanResult] and affects
  /// convenience getters such as `isNsfw`; the raw labels remain available.
  Future<ScanResult> scanAsset(
    String localIdentifier, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final t = confidenceThreshold ?? _defaultThreshold;
    final map =
        await _platform.scanSingleAsset(localIdentifier, modelId: modelId);
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
  /// confidence.
  Future<ScanResult> scanFile(
    String filePath, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final t = confidenceThreshold ?? _defaultThreshold;
    final map = await _platform.scanFilePath(filePath, modelId: modelId);
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
  /// enough for the target devices.
  Future<ScanResult> scanBytes(
    Uint8List bytes, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final t = confidenceThreshold ?? _defaultThreshold;
    final map = await _platform.scanImageBytes(bytes, modelId: modelId);
    return ScanResult.fromMap(map, confidenceThreshold: t);
  }

  /// Boolean shortcut over [scanFile] — returns whether the file crosses the
  /// NSFW threshold. Use this for simple gate checks where you don't need
  /// the full [ScanResult].
  Future<bool> isNsfwFile(
    String filePath, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final result = await scanFile(
      filePath,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
    );
    return result.isNsfw;
  }

  /// Boolean shortcut over [scanBytes] — returns whether the bytes cross the
  /// NSFW threshold.
  Future<bool> isNsfwBytes(
    Uint8List bytes, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final result = await scanBytes(
      bytes,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
    );
    return result.isNsfw;
  }

  /// Boolean shortcut over [scanAsset] — returns whether a photo-library
  /// asset crosses the NSFW threshold.
  Future<bool> isNsfwAsset(
    String localIdentifier, {
    String? modelId,
    double? confidenceThreshold,
  }) async {
    final result = await scanAsset(
      localIdentifier,
      modelId: modelId,
      confidenceThreshold: confidenceThreshold,
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
  }) =>
      _scanBatch<String>(
        paths,
        (p) => scanFile(p,
            modelId: modelId, confidenceThreshold: confidenceThreshold),
        onProgress: onProgress,
        confidenceThreshold: confidenceThreshold ?? _defaultThreshold,
        identifierFor: (p) => p,
      );

  /// Scans every byte buffer in [items] sequentially. See [scanFiles] for
  /// progress and error semantics.
  Future<List<ScanResult>> scanAllBytes(
    List<Uint8List> items, {
    String? modelId,
    double? confidenceThreshold,
    void Function(int completed, int total)? onProgress,
  }) =>
      _scanBatch<Uint8List>(
        items,
        (b) => scanBytes(b,
            modelId: modelId, confidenceThreshold: confidenceThreshold),
        onProgress: onProgress,
        confidenceThreshold: confidenceThreshold ?? _defaultThreshold,
        identifierFor: (_) => '',
      );

  /// Scans every photo-library local identifier in [localIdentifiers]
  /// sequentially. See [scanFiles] for progress and error semantics.
  Future<List<ScanResult>> scanAssets(
    List<String> localIdentifiers, {
    String? modelId,
    double? confidenceThreshold,
    void Function(int completed, int total)? onProgress,
  }) =>
      _scanBatch<String>(
        localIdentifiers,
        (id) => scanAsset(id,
            modelId: modelId, confidenceThreshold: confidenceThreshold),
        onProgress: onProgress,
        confidenceThreshold: confidenceThreshold ?? _defaultThreshold,
        identifierFor: (id) => id,
      );

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
}
