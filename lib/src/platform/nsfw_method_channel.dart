import 'dart:async';
import 'package:flutter/services.dart';
import '../api/camera_configuration.dart';
import '../api/model_descriptor.dart';
import '../api/permissions/permission_kind.dart';
import '../api/scan_configuration.dart';
import 'nsfw_platform_interface.dart';

class NsfwMethodChannel extends NsfwPlatformInterface {
  static const _methodChannel = MethodChannel('nsfw_detect_ios/methods');
  static const _eventChannel = EventChannel('nsfw_detect_ios/scan_events');

  late final Stream<Map<dynamic, dynamic>> _scanEvents = _eventChannel
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .cast<Map<dynamic, dynamic>>();

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => _scanEvents;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async {
    final result =
        await _methodChannel.invokeMethod<String>('requestPermission');
    return PhotoLibraryPermissionStatus.fromString(result ?? 'notDetermined');
  }

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async {
    final result = await _methodChannel.invokeMethod<String>('checkPermission');
    return PhotoLibraryPermissionStatus.fromString(result ?? 'notDetermined');
  }

  @override
  Future<List<ModelDescriptor>> availableModels() async {
    final result =
        await _methodChannel.invokeListMethod<Map>('availableModels');
    return (result ?? []).map(ModelDescriptor.fromMap).toList();
  }

  @override
  Future<void> preloadModel(String modelId) async {
    await _methodChannel
        .invokeMethod<void>('preloadModel', {'modelId': modelId});
  }

  @override
  Future<void> startScan(ScanConfiguration config) async {
    await _methodChannel.invokeMethod<void>('startScan', config.toChannelMap());
  }

  @override
  Future<void> cancelScan() async {
    await _methodChannel.invokeMethod<void>('cancelScan');
  }

  @override
  Future<void> resetScan() async {
    await _methodChannel.invokeMethod<void>('resetScan');
  }

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(
    String localIdentifier, {
    String? modelId,
    Map<String, double>? roi,
  }) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanSingleAsset',
      {
        'localId': localIdentifier,
        if (modelId != null) 'modelId': modelId,
        if (roi != null) 'roi': roi,
      },
    );
    return result ?? {};
  }

  @override
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems) async {
    await _methodChannel.invokeMethod<void>('pickAndScan', {
      ...config.toChannelMap(),
      'maxItems': maxItems,
    });
  }

  @override
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) async {
    final result = await _methodChannel.invokeListMethod<Map<dynamic, dynamic>>(
      'pickMedia',
      {
        'type': type,
        'multiple': multiple,
        if (maxItems != null) 'maxItems': maxItems,
      },
    );
    return result ?? const [];
  }

  @override
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
      {String? modelId, Map<String, double>? roi}) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanFile',
      {
        'filePath': filePath,
        if (modelId != null) 'modelId': modelId,
        if (roi != null) 'roi': roi,
      },
    );
    return result ?? {};
  }

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
      {String? modelId, Map<String, double>? roi}) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanBytes',
      {
        'bytes': bytes,
        if (modelId != null) 'modelId': modelId,
        if (roi != null) 'roi': roi,
      },
    );
    return result ?? {};
  }

  @override
  Future<bool> downloadModel(String modelId, {String? url}) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'downloadModel',
      {'modelId': modelId, if (url != null) 'url': url},
    );
    return result ?? false;
  }

  @override
  Future<void> deleteModel(String modelId) async {
    await _methodChannel
        .invokeMethod<void>('deleteModel', {'modelId': modelId});
  }

  @override
  Future<void> setModelUrl(String modelId, String url) async {
    await _methodChannel
        .invokeMethod<void>('setModelUrl', {'modelId': modelId, 'url': url});
  }

  @override
  Future<void> setLogging(bool enabled) async {
    await _methodChannel.invokeMethod<void>('setLogging', {'enabled': enabled});
  }

  @override
  Future<void> clearScanCache({String? modelId}) async {
    await _methodChannel.invokeMethod<void>(
      'clearScanCache',
      {if (modelId != null) 'modelId': modelId},
    );
  }

  @override
  Future<void> scheduleBackgroundSweep(Map<String, Object?> options) async {
    try {
      await _methodChannel.invokeMethod<void>('scheduleBackgroundSweep', options);
    } on MissingPluginException {
      throw UnimplementedError(
          'scheduleBackgroundSweep is not yet wired on this platform — see BackgroundSweepOptions docs');
    } on PlatformException catch (e) {
      // Native side raises specific failure codes (HOST_APP_NOT_CONFIGURED
      // for missing Info.plist identifier, etc). Surface as a typed error
      // so callers can branch on it.
      if (e.code == 'HOST_APP_NOT_CONFIGURED') {
        throw StateError(
          'Background sweep unavailable — ${e.message ?? "host app not configured"}',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> cancelBackgroundSweep() async {
    try {
      await _methodChannel.invokeMethod<void>('cancelBackgroundSweep');
    } on MissingPluginException {
      // No-op when the native side hasn't been wired.
    }
  }

  @override
  Future<String> registerModel(Map<String, Object?> registration) async {
    final result = await _methodChannel.invokeMethod<String>(
      'registerModel',
      registration,
    );
    if (result == null || result.isEmpty) {
      throw StateError('registerModel returned no resolved path');
    }
    return result;
  }

  @override
  Future<void> skipCurrentAsset() async {
    try {
      await _methodChannel.invokeMethod<void>('skipCurrentAsset');
    } on MissingPluginException {
      // Native side hasn't shipped this yet — silent no-op.
    }
  }

  @override
  Future<Map<dynamic, dynamic>?> cachedResult(
    String localIdentifier, {
    String? modelId,
  }) async {
    try {
      final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
        'cachedResult',
        {
          'localId': localIdentifier,
          if (modelId != null) 'modelId': modelId,
        },
      );
      return result;
    } on MissingPluginException {
      // Platform hasn't shipped this yet — degrade gracefully to a miss.
      return null;
    }
  }

  @override
  Future<void> prefetchAssets(
    List<String> localIdentifiers, {
    String? modelId,
  }) async {
    if (localIdentifiers.isEmpty) return;
    try {
      await _methodChannel.invokeMethod<void>(
        'prefetchAssets',
        {
          'localIds': localIdentifiers,
          if (modelId != null) 'modelId': modelId,
        },
      );
    } on MissingPluginException {
      // No-op: platforms without a warm-cache impl just skip prefetching.
    }
  }

  @override
  Future<Uint8List> redactBytes({
    required Uint8List bytes,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputFormat,
  }) async {
    final result = await _methodChannel.invokeMethod<Uint8List>(
      'redactBytes',
      {
        'bytes': bytes,
        'detections': detections,
        'mode': mode,
        'intensity': intensity,
        if (outputFormat != null) 'outputFormat': outputFormat,
      },
    );
    if (result == null) {
      throw StateError('redactBytes returned null from the platform channel');
    }
    return result;
  }

  @override
  Future<String> redactFile({
    required String inputPath,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputPath,
  }) async {
    final result = await _methodChannel.invokeMethod<String>(
      'redactFile',
      {
        'inputPath': inputPath,
        'detections': detections,
        'mode': mode,
        'intensity': intensity,
        if (outputPath != null) 'outputPath': outputPath,
      },
    );
    if (result == null || result.isEmpty) {
      throw StateError('redactFile returned no output path');
    }
    return result;
  }

  @override
  Future<void> startCameraScan(CameraConfiguration config) async {
    await _methodChannel.invokeMethod<void>(
      'startCameraScan',
      config.toChannelMap(),
    );
  }

  @override
  Future<void> stopCameraScan() async {
    await _methodChannel.invokeMethod<void>('stopCameraScan');
  }

  @override
  Future<PermissionStatus> checkCameraPermission() async {
    try {
      final result =
          await _methodChannel.invokeMethod<String>('checkCameraPermission');
      return PermissionStatus.fromString(result);
    } on MissingPluginException {
      // Native handler not yet wired (Phase 2 / 3). Surface as
      // UnimplementedError so NsfwDetector can degrade to notDetermined.
      throw UnimplementedError('checkCameraPermission not implemented');
    }
  }

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    try {
      final result =
          await _methodChannel.invokeMethod<String>('requestCameraPermission');
      return PermissionStatus.fromString(result);
    } on MissingPluginException {
      throw UnimplementedError('requestCameraPermission not implemented');
    }
  }
}
