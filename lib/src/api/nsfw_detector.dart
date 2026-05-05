import 'dart:async';
import 'dart:typed_data';
import 'model_download_progress.dart';
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

  // Permission
  Future<PhotoLibraryPermissionStatus> requestPermission() =>
      _platform.requestPermission();
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

  // Models
  Future<List<ModelDescriptor>> availableModels() =>
      _platform.availableModels();
  Future<void> preloadModel(String modelId) => _platform.preloadModel(modelId);

  // Start a full library scan
  Future<ScanSession> startScan(ScanConfiguration config) =>
      ScanSession.start(config: config, platform: _platform);
  Future<void> resetScan() => _platform.resetScan();

  // Model download
  Future<bool> downloadModel(String modelId, {String? url}) =>
      _platform.downloadModel(modelId, url: url);
  Future<void> deleteModel(String modelId) => _platform.deleteModel(modelId);
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
  Future<CameraScanSession> startCameraScan([CameraConfiguration? config]) async {
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

  // Scan a single asset by its PHAsset local identifier
  Future<ScanResult> scanAsset(
    String localIdentifier, {
    String? modelId,
    double confidenceThreshold = 0.7,
  }) async {
    final map =
        await _platform.scanSingleAsset(localIdentifier, modelId: modelId);
    return ScanResult.fromMap(map, confidenceThreshold: confidenceThreshold);
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
  Future<ScanResult> scanFile(
    String filePath, {
    String? modelId,
    double confidenceThreshold = 0.7,
  }) async {
    final map = await _platform.scanFilePath(filePath, modelId: modelId);
    return ScanResult.fromMap(map, confidenceThreshold: confidenceThreshold);
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
  Future<ScanResult> scanBytes(
    Uint8List bytes, {
    String? modelId,
    double confidenceThreshold = 0.7,
  }) async {
    final map = await _platform.scanImageBytes(bytes, modelId: modelId);
    return ScanResult.fromMap(map, confidenceThreshold: confidenceThreshold);
  }
}
