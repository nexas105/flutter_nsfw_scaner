// Pattern: copy this to your app's test dir.
//
// A drop-in fake platform implementation for `nsfw_detect`. Wire it via
// `NsfwPlatformInterface.instance = FakeNsfwPlatform(...)` at the top of
// each test so the production `NsfwDetector.instance` runs against scripted
// scan results instead of a real method channel.
//
// This file deliberately lives under `test/_fakes/` rather than `lib/src/`
// so downstream apps can vendor it without taking a dependency on
// `package:nsfw_detect/testing/...`. Copy the file as-is into your own
// `test/` tree; it is API-stable against the public plugin surface.

import 'dart:async';
import 'dart:typed_data';

import 'package:nsfw_detect/nsfw_detect.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Recorded call to one of the fake's scan APIs — handy for asserting that
/// the unit under test actually invoked the platform layer.
class FakeNsfwCall {
  final String method;
  final Map<String, Object?> args;
  const FakeNsfwCall(this.method, this.args);

  @override
  String toString() => 'FakeNsfwCall($method, $args)';
}

/// Tiny fake [NsfwPlatformInterface]. Returns scripted [ScanResult]s and
/// records every API call so tests can assert end-to-end behaviour without
/// booting the native plugin.
class FakeNsfwPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  /// Per-`localId` scripted result. When no script is set the fake returns a
  /// safe placeholder so tests don't accidentally fail-closed.
  final Map<String, ScanResult> results;

  /// Pretend permission grant.
  PhotoLibraryPermissionStatus permissionStatus;

  /// Pretend camera permission grant.
  PermissionStatus cameraStatus;

  /// Native model registry.
  final List<ModelDescriptor> models;

  /// Captured API calls in invocation order.
  final List<FakeNsfwCall> calls = [];

  final StreamController<Map<dynamic, dynamic>> _events =
      StreamController.broadcast();

  /// Scripted queue of [ScanResult]s replayed by [scanImageBytes] — drained
  /// in order so the FrameStreamScanner sees deterministic responses per
  /// accepted frame. When empty, falls back to [_resultFor].
  final List<ScanResult> _frameResults = <ScanResult>[];

  /// Broadcast stream of frame results — convenience hook for the
  /// FrameStreamScanner test so it can listen to the same events the
  /// `scanImageBytes` call produced. Closed in [dispose].
  Stream<ScanResult> get frames => _framesController.stream;
  final StreamController<ScanResult> _framesController =
      StreamController<ScanResult>.broadcast();

  /// Seed a scripted sequence of [ScanResult]s returned (in order) by
  /// subsequent [scanImageBytes] calls. Once the queue is drained the fake
  /// falls back to its default safe placeholder.
  void seedFrameResults(List<ScanResult> results) {
    _frameResults
      ..clear()
      ..addAll(results);
  }

  FakeNsfwPlatform({
    Map<String, ScanResult>? results,
    this.permissionStatus = PhotoLibraryPermissionStatus.authorized,
    this.cameraStatus = PermissionStatus.authorized,
    List<ModelDescriptor>? models,
  })  : results = results ?? {},
        models = models ??
            const [
              ModelDescriptor(
                id: ModelIds.openNsfw2,
                displayName: 'OpenNSFW2 (fake)',
              ),
            ];

  /// Replay or synthesize a [ScanResult] for [localId]. Override [results] to
  /// script the response per test.
  ScanResult _resultFor(String localId) {
    final scripted = results[localId];
    if (scripted != null) return scripted;
    return ScanResult.fake(
      localIdentifier: localId,
      category: NsfwCategory.safe,
      confidence: 0.99,
    );
  }

  /// Emit a synthetic native event — useful for testing model-download UIs.
  void emitNativeEvent(Map<String, Object?> event) => _events.add(event);

  // ── Permissions ──────────────────────────────────────────────────────────
  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async {
    calls.add(const FakeNsfwCall('requestPermission', {}));
    return permissionStatus;
  }

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async {
    calls.add(const FakeNsfwCall('checkPermission', {}));
    return permissionStatus;
  }

  @override
  Future<PermissionStatus> checkCameraPermission() async {
    calls.add(const FakeNsfwCall('checkCameraPermission', {}));
    return cameraStatus;
  }

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    calls.add(const FakeNsfwCall('requestCameraPermission', {}));
    return cameraStatus;
  }

  // ── Models ───────────────────────────────────────────────────────────────
  @override
  Future<List<ModelDescriptor>> availableModels() async {
    calls.add(const FakeNsfwCall('availableModels', {}));
    return models;
  }

  @override
  Future<void> preloadModel(String modelId) async {
    calls.add(FakeNsfwCall('preloadModel', {'modelId': modelId}));
  }

  @override
  Future<bool> downloadModel(String modelId, {String? url}) async {
    calls.add(
        FakeNsfwCall('downloadModel', {'modelId': modelId, 'url': url}));
    return true;
  }

  @override
  Future<void> deleteModel(String modelId) async {
    calls.add(FakeNsfwCall('deleteModel', {'modelId': modelId}));
  }

  @override
  Future<void> setModelUrl(String modelId, String url) async {
    calls.add(FakeNsfwCall('setModelUrl', {'modelId': modelId, 'url': url}));
  }

  // ── Scan lifecycle ───────────────────────────────────────────────────────
  @override
  Future<void> startScan(ScanConfiguration config) async {
    calls.add(FakeNsfwCall('startScan', {'config': config}));
  }

  @override
  Future<void> cancelScan() async {
    calls.add(const FakeNsfwCall('cancelScan', {}));
  }

  @override
  Future<void> startCameraScan(CameraConfiguration config) async {
    calls.add(FakeNsfwCall('startCameraScan', {'config': config}));
  }

  @override
  Future<void> stopCameraScan() async {
    calls.add(const FakeNsfwCall('stopCameraScan', {}));
  }

  // ── Scan APIs ────────────────────────────────────────────────────────────
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId, Map<String, double>? roi}) async {
    calls.add(FakeNsfwCall('scanSingleAsset', {
      'localId': localIdentifier,
      'modelId': modelId,
      'roi': roi,
    }));
    return _resultFor(localIdentifier).toMap();
  }

  @override
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
      {String? modelId, Map<String, double>? roi}) async {
    calls.add(FakeNsfwCall('scanFilePath', {
      'filePath': filePath,
      'modelId': modelId,
      'roi': roi,
    }));
    return _resultFor(filePath).toMap();
  }

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
      {String? modelId, Map<String, double>? roi}) async {
    calls.add(FakeNsfwCall('scanImageBytes', {
      'length': bytes.length,
      'modelId': modelId,
      'roi': roi,
    }));
    // Prefer scripted frame results when seeded — drained in order.
    ScanResult result;
    if (_frameResults.isNotEmpty) {
      result = _frameResults.removeAt(0);
    } else {
      // Use a stable identifier so callers can script by byte length.
      result = _resultFor('bytes:${bytes.length}');
    }
    if (!_framesController.isClosed) _framesController.add(result);
    return result.toMap();
  }

  @override
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) async {
    calls.add(FakeNsfwCall('pickMedia',
        {'type': type, 'multiple': multiple, 'maxItems': maxItems}));
    return const [];
  }

  // ── Misc ─────────────────────────────────────────────────────────────────
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => _events.stream;

  /// Test-only: shut the event controller down at the end of a test.
  void dispose() {
    _events.close();
    if (!_framesController.isClosed) _framesController.close();
  }
}
