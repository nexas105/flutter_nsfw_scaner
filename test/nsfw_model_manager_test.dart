import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Minimal platform whose `downloadModel` emits two progress events (50 %,
/// then complete) on the shared scan event stream — the same wire shape the
/// native sides produce.
class _FakeDownloadPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  final events = StreamController<Map<dynamic, dynamic>>.broadcast();
  int downloadCalls = 0;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async =>
      PhotoLibraryPermissionStatus.authorized;

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async =>
      PhotoLibraryPermissionStatus.authorized;

  @override
  Future<List<ModelDescriptor>> availableModels() async => const [
        ModelDescriptor(
          id: 'dl_model',
          displayName: 'Downloadable',
          requiresDownload: true,
          isDownloaded: false,
          downloadSizeBytes: 1000,
        ),
      ];

  @override
  Future<bool> downloadModel(String modelId, {String? url}) async {
    downloadCalls++;
    scheduleMicrotask(() {
      events.add({
        'type': 'modelDownloadProgress',
        'modelId': modelId,
        'fraction': 0.5,
        'bytesDownloaded': 500,
        'totalBytes': 1000,
      });
      events.add({
        'type': 'modelDownloadProgress',
        'modelId': modelId,
        'fraction': 1.0,
        'bytesDownloaded': 1000,
        'totalBytes': 1000,
      });
    });
    return true;
  }

  @override
  Future<void> startScan(ScanConfiguration config) async {}
  @override
  Future<void> cancelScan() async {}
  @override
  Future<void> resetScan() async {}
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId, Map<String, double>? roi}) async =>
      {};
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => events.stream;
  @override
  Future<void> startCameraScan(CameraConfiguration config) async {}
  @override
  Future<void> stopCameraScan() async {}
}

void main() {
  late _FakeDownloadPlatform platform;

  setUpAll(() {
    platform = _FakeDownloadPlatform();
    NsfwPlatformInterface.instance = platform;
  });

  tearDownAll(() => platform.events.close());

  group('NsfwDetector.downloadProgress', () {
    test('two concurrent listeners both receive the same events', () async {
      final a = <double>[];
      final b = <double>[];
      final subA =
          NsfwDetector.instance.downloadProgress.listen((p) => a.add(p.fraction));
      final subB =
          NsfwDetector.instance.downloadProgress.listen((p) => b.add(p.fraction));

      platform.events.add({
        'type': 'modelDownloadProgress',
        'modelId': 'x',
        'fraction': 0.25,
      });
      platform.events.add({
        'type': 'modelDownloadProgress',
        'modelId': 'x',
        'fraction': 1.0,
      });
      await Future<void>.delayed(Duration.zero);

      expect(a, [0.25, 1.0]);
      expect(b, [0.25, 1.0]);

      await subA.cancel();
      await subB.cancel();
    });

    test('re-attaches to the native stream after all listeners cancelled',
        () async {
      final got = <double>[];
      final sub =
          NsfwDetector.instance.downloadProgress.listen((p) => got.add(p.fraction));
      platform.events.add({
        'type': 'modelDownloadProgress',
        'modelId': 'y',
        'fraction': 0.75,
      });
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(got, [0.75]);
    });
  });

  group('NsfwModelManager.ensureReady', () {
    test('can be called repeatedly without "already listened to"', () async {
      final manager = NsfwDetector.instance.models;
      // Long-lived state listener — this is the first subscription on the
      // shared progress stream, the ensureReady ones below are the 2nd/3rd.
      final states = <ModelStatus>[];
      final sub = manager.changes.listen((s) => states.add(s.status));

      final progressA = <double>[];
      await manager.ensureReady('dl_model',
          onProgress: (p) => progressA.add(p.fraction));
      final progressB = <double>[];
      await manager.ensureReady('dl_model',
          onProgress: (p) => progressB.add(p.fraction));

      expect(platform.downloadCalls, 2);
      expect(progressA, [0.5, 1.0]);
      expect(progressB, [0.5, 1.0]);
      expect(states, contains(ModelStatus.downloaded));

      await sub.cancel();
    });
  });
}
