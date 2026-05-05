import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import '../api/model_descriptor.dart';
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
}

/// Platform-interface contract for nsfw_detect.
///
/// Methods are split into two groups:
///   * **Lifecycle / critical** (abstract — every implementation must provide
///     them): permission, model listing, scan lifecycle, single-asset scan,
///     and the raw event stream. Without these the plugin cannot function.
///   * **Optional / feature** (default impls below): model download, custom
///     URL, logging, cache, picker, file/bytes scanning, upload-user-id.
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

  // Single asset
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId});

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

  /// Scan an image file from path. Default throws.
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
          {String? modelId}) =>
      throw UnimplementedError(
          'scanFilePath is not implemented by this platform');

  /// Scan raw image bytes. Default throws.
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
          {String? modelId}) =>
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

  /// Persist the user identifier used as the first segment of the upload key.
  /// Default no-op so test mocks don't need to implement the optional
  /// per-user upload pathing.
  Future<void> setUploadUserId(String userId) async {}

  /// Read the currently-persisted upload user id (or null if none).
  /// Default returns null.
  Future<String?> getUploadUserId() async => null;
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
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId}) =>
      throw UnimplementedError();
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      throw UnimplementedError();
}
