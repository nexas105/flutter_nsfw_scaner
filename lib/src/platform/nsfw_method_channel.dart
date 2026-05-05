import 'dart:async';
import 'package:flutter/services.dart';
import '../api/model_descriptor.dart';
import '../api/scan_configuration.dart';
import 'nsfw_platform_interface.dart';

class NsfwMethodChannel extends NsfwPlatformInterface {
  static const _methodChannel = MethodChannel('nsfw_detect_ios/methods');
  static const _eventChannel = EventChannel('nsfw_detect_ios/scan_events');

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream {
    // Create a fresh stream each time — the previous stream is dead
    // after cancel/completion. Caching would return a closed stream.
    return _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .cast<Map<dynamic, dynamic>>();
  }

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
    return (result ?? []).map((m) => ModelDescriptor.fromMap(m)).toList();
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
  }) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanSingleAsset',
      {'localId': localIdentifier, if (modelId != null) 'modelId': modelId},
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
      {String? modelId}) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanFile',
      {'filePath': filePath, if (modelId != null) 'modelId': modelId},
    );
    return result ?? {};
  }

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
      {String? modelId}) async {
    final result = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'scanBytes',
      {'bytes': bytes, if (modelId != null) 'modelId': modelId},
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
}
