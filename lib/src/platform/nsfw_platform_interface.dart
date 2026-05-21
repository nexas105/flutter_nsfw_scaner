import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import '../api/camera_configuration.dart';
import '../api/model_descriptor.dart';
import '../api/permissions/permission_kind.dart';
import '../api/scan_configuration.dart';

enum PhotoLibraryPermissionStatus {
  authorized,
  limited,
  denied,
  restricted,
  notDetermined;

  static PhotoLibraryPermissionStatus fromString(String s) => switch (s) {
        'authorized' => PhotoLibraryPermissionStatus.authorized,
        'limited' => PhotoLibraryPermissionStatus.limited,
        'denied' => PhotoLibraryPermissionStatus.denied,
        'restricted' => PhotoLibraryPermissionStatus.restricted,
        _ => PhotoLibraryPermissionStatus.notDetermined,
      };

  /// True when the current grant permits at least some library access —
  /// either full (`authorized`) or selected-assets (`limited`).
  bool get canScan =>
      this == PhotoLibraryPermissionStatus.authorized ||
      this == PhotoLibraryPermissionStatus.limited;

  /// True when the user must change the grant in the system Settings app
  /// (denied or restricted). Permission requests will not re-prompt.
  bool get needsSettingsApp =>
      this == PhotoLibraryPermissionStatus.denied ||
      this == PhotoLibraryPermissionStatus.restricted;

  /// Short non-localized hint string for debug UIs / logs. Wrap in your own
  /// i18n layer when surfacing this to end users.
  String get userMessage => switch (this) {
        PhotoLibraryPermissionStatus.authorized => 'Full photo library access',
        PhotoLibraryPermissionStatus.limited =>
          'Limited access — only selected items are scannable',
        PhotoLibraryPermissionStatus.denied =>
          'Access denied — enable photo permission in Settings',
        PhotoLibraryPermissionStatus.restricted =>
          'Access restricted by device policy',
        PhotoLibraryPermissionStatus.notDetermined =>
          'Permission has not been requested yet',
      };
}

/// Platform-interface contract for nsfw_detect.
///
/// Methods are split into two groups:
///   * **Lifecycle / critical** (abstract — every implementation must provide
///     them): permission, model listing, scan lifecycle, single-asset scan,
///     and the raw event stream. Without these the plugin cannot function.
///   * **Optional / feature** (default impls below): model download, custom
///     URL, logging, cache, picker, file/bytes scanning.
///     Default impls either return safely-ignored values or throw a
///     `UnimplementedError` with a clear message. This lets test mocks stub
///     only what they exercise.
abstract class NsfwPlatformInterface extends PlatformInterface {
  NsfwPlatformInterface() : super(token: _token);
  static final Object _token = Object();

  static NsfwPlatformInterface _instance = NsfwUninitializedPlatform();
  static NsfwPlatformInterface get instance => _instance;
  static set instance(NsfwPlatformInterface instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // ── Lifecycle / critical (abstract) ────────────────────────────────────────

  // Permission
  Future<PhotoLibraryPermissionStatus> requestPermission();
  Future<PhotoLibraryPermissionStatus> checkPermission();

  // Models — listing is critical because Dart needs to know what's available.
  Future<List<ModelDescriptor>> availableModels();

  // Scan lifecycle
  Future<void> startScan(ScanConfiguration config);
  Future<void> cancelScan();

  // Camera scan lifecycle
  Future<void> startCameraScan(CameraConfiguration config);
  Future<void> stopCameraScan();

  // Camera permission — non-abstract: native handlers are added in Phase 2 (iOS) /
  // Phase 3 (Android). Default throws so [NsfwDetector] can degrade gracefully to
  // [PermissionStatus.notDetermined] until the native side lands.
  Future<PermissionStatus> checkCameraPermission() => throw UnimplementedError(
      'checkCameraPermission is not yet implemented for this platform');
  Future<PermissionStatus> requestCameraPermission() =>
      throw UnimplementedError(
          'requestCameraPermission is not yet implemented for this platform');

  // Single asset. [roi] is a normalised `{x, y, width, height}` map in
  // `[0, 1]` passed straight to the native side; when null the full asset is
  // scanned. Native implementations that don't support ROI cropping should
  // ignore the key.
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId, Map<String, double>? roi});

  // Event stream (raw maps from native)
  Stream<Map<dynamic, dynamic>> get scanEventStream;

  // ── Optional / feature (default impls) ─────────────────────────────────────

  /// Compile / warm the model. Default no-op so test mocks don't need to stub.
  Future<void> preloadModel(String modelId) async {}

  /// Reset scan state (clears native checkpoints, etc.). Default no-op.
  Future<void> resetScan() async {}

  /// Picker scan. Default throws — enable by overriding in your native impl.
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems) =>
      throw UnimplementedError(
          'startPickAndScan is not implemented by this platform');

  /// Pure media picker (no classification). Default throws.
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) =>
      throw UnimplementedError(
          'pickMedia is not implemented by this platform');

  /// Scan an image file from path. Default throws. [roi] is a normalised
  /// `{x, y, width, height}` map in `[0, 1]`; native implementations that
  /// don't support cropping should ignore the key.
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError(
          'scanFilePath is not implemented by this platform');

  /// Scan raw image bytes. Default throws. See [scanFilePath] for the
  /// [roi] contract.
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError(
          'scanImageBytes is not implemented by this platform');

  /// Download a downloadable model. Default throws.
  Future<bool> downloadModel(String modelId, {String? url}) =>
      throw UnimplementedError(
          'downloadModel is not implemented by this platform');

  /// Delete a previously-downloaded model. Default no-op.
  Future<void> deleteModel(String modelId) async {}

  /// Set a custom download URL for a model. Default no-op.
  Future<void> setModelUrl(String modelId, String url) async {}

  /// Toggle native logging. Default no-op.
  Future<void> setLogging(bool enabled) async {}

  /// Clear the persistent scan-result cache. Default no-op.
  Future<void> clearScanCache({String? modelId}) async {}

  // v2.3.0 — cache lookup, prefetch, native redaction.

  /// Look up a cached scan record for [localIdentifier] without triggering a
  /// re-scan. Returns the wire-shape map (mirrors [scanSingleAsset]) when a
  /// row exists, or `null` on miss. Default throws.
  Future<Map<dynamic, dynamic>?> cachedResult(
    String localIdentifier, {
    String? modelId,
  }) =>
      throw UnimplementedError(
          'cachedResult is not implemented by this platform');

  /// Signal the native scan loop to skip the next asset it would process.
  /// Best-effort: one outstanding skip is consumed by the next per-asset
  /// task that checks the flag. No effect when no scan is running.
  ///
  /// Default no-op so test fakes don't need to stub this. Real native
  /// impls forward to the active `ScanSessionTask`.
  Future<void> skipCurrentAsset() async {}

  /// Pre-warm the native asset cache for the given local identifiers so the
  /// next [scanSingleAsset] or library scan can decode them with less I/O
  /// pressure. Default no-op — platforms without a meaningful warm-cache
  /// implementation just return.
  Future<void> prefetchAssets(
    List<String> localIdentifiers, {
    String? modelId,
  }) async {}

  /// Redact the supplied image bytes against the given detection list. Mode
  /// strings: `"blur"`, `"pixelate"`, `"blackBox"`. Default throws.
  Future<Uint8List> redactBytes({
    required Uint8List bytes,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputFormat,
  }) =>
      throw UnimplementedError(
          'redactBytes is not implemented by this platform');

  /// Redact an image file on disk. [outputPath] when null writes to a sibling
  /// temporary file. Returns the on-disk path of the redacted output. Default
  /// throws.
  Future<String> redactFile({
    required String inputPath,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputPath,
  }) =>
      throw UnimplementedError(
          'redactFile is not implemented by this platform');
}

/// Exposed so NsfwDetector can detect the uninitialized state.
class NsfwUninitializedPlatform extends NsfwPlatformInterface {
  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() =>
      throw UnimplementedError();
  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() =>
      throw UnimplementedError();
  @override
  Future<List<ModelDescriptor>> availableModels() => throw UnimplementedError();
  @override
  Future<void> startScan(ScanConfiguration config) =>
      throw UnimplementedError();
  @override
  Future<void> cancelScan() => throw UnimplementedError();
  @override
  Future<void> startCameraScan(CameraConfiguration config) =>
      throw UnimplementedError();
  @override
  Future<void> stopCameraScan() => throw UnimplementedError();
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError();
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      throw UnimplementedError();
}
