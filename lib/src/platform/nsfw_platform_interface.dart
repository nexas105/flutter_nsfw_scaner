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

abstract class NsfwPlatformInterface extends PlatformInterface {
  NsfwPlatformInterface() : super(token: _token);
  static final Object _token = Object();

  static NsfwPlatformInterface _instance = NsfwUninitializedPlatform();
  static NsfwPlatformInterface get instance => _instance;
  static set instance(NsfwPlatformInterface instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // Permission
  Future<PhotoLibraryPermissionStatus> requestPermission();
  Future<PhotoLibraryPermissionStatus> checkPermission();

  // Models
  Future<List<ModelDescriptor>> availableModels();
  Future<void> preloadModel(String modelId);

  // Scan lifecycle
  Future<void> startScan(ScanConfiguration config);
  Future<void> cancelScan();
  Future<void> resetScan();

  // Single asset
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId});

  // Picker scan
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems);

  // Pure media picker (no classification)
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  });

  // File / bytes scan
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
      {String? modelId});
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
      {String? modelId});

  // Model download
  Future<bool> downloadModel(String modelId, {String? url});
  Future<void> deleteModel(String modelId);
  Future<void> setModelUrl(String modelId, String url);

  // Logging
  Future<void> setLogging(bool enabled);

  // Incremental-scan cache
  Future<void> clearScanCache({String? modelId});

  // Event stream (raw maps from native)
  Stream<Map<dynamic, dynamic>> get scanEventStream;
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
  Future<void> preloadModel(String modelId) => throw UnimplementedError();
  @override
  Future<void> startScan(ScanConfiguration config) =>
      throw UnimplementedError();
  @override
  Future<void> cancelScan() => throw UnimplementedError();
  @override
  Future<void> resetScan() => throw UnimplementedError();
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId}) =>
      throw UnimplementedError();
  @override
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems) =>
      throw UnimplementedError();
  @override
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) =>
      throw UnimplementedError();
  @override
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
          {String? modelId}) =>
      throw UnimplementedError();
  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
          {String? modelId}) =>
      throw UnimplementedError();
  @override
  Future<bool> downloadModel(String modelId, {String? url}) =>
      throw UnimplementedError();
  @override
  Future<void> deleteModel(String modelId) => throw UnimplementedError();
  @override
  Future<void> setModelUrl(String modelId, String url) =>
      throw UnimplementedError();
  @override
  Future<void> setLogging(bool enabled) => throw UnimplementedError();
  @override
  Future<void> clearScanCache({String? modelId}) => throw UnimplementedError();
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      throw UnimplementedError();
}
