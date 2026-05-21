import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Minimal platform mock — only stubs the lifecycle/critical surface that
/// NsfwScanController exercises (T3 ships defaults for the rest).
class _MockPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  PhotoLibraryPermissionStatus permission =
      PhotoLibraryPermissionStatus.authorized;

  final scanEvents = StreamController<Map<dynamic, dynamic>>.broadcast();
  bool startScanCalled = false;
  bool cancelScanCalled = false;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async => permission;
  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async => permission;
  @override
  Future<List<ModelDescriptor>> availableModels() async =>
      const [ModelDescriptor(id: 'm', displayName: 'M')];
  @override
  Future<void> startScan(ScanConfiguration config) async {
    startScanCalled = true;
  }

  @override
  Future<void> cancelScan() async {
    cancelScanCalled = true;
    // Simulate native progress flush so ScanSession resolves done.
    scanEvents.add({
      'type': 'progress',
      'scannedCount': 0,
      'totalCount': 0,
      'isComplete': false,
    });
  }

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId, Map<String, double>? roi}) async =>
      {};

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => scanEvents.stream;

  @override
  Future<void> startCameraScan(CameraConfiguration config) async {}

  @override
  Future<void> stopCameraScan() async {}

  void dispose() => scanEvents.close();
}

Map<String, dynamic> _resultMap(String id, {double conf = 0.95}) => {
      'type': 'result',
      'localId': id,
      'mediaType': 'image',
      'status': 'completed',
      'scannedAt': DateTime.now().millisecondsSinceEpoch,
      'labels': [
        {'category': 'nudity', 'confidence': conf},
      ],
    };

void main() {
  late _MockPlatform mock;

  setUp(() {
    mock = _MockPlatform();
    NsfwPlatformInterface.instance = mock;
  });

  tearDown(() => mock.dispose());

  test('initial state after constructor', () {
    final controller = NsfwScanController();
    expect(controller.permissionStatus, isNull);
    expect(controller.session, isNull);
    expect(controller.isScanning, isFalse);
    expect(controller.wasStopped, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.results, isEmpty);
    expect(controller.lastProgress, isNull);
    expect(controller.config, const ScanConfiguration());
    controller.dispose();
  });

  test('startScan sets isScanning=true and populates items as results stream',
      () async {
    final controller = NsfwScanController();
    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    await controller.startScan();
    expect(controller.isScanning, isTrue);
    expect(mock.startScanCalled, isTrue);

    // Pump a result event through the platform's event stream.
    mock.scanEvents.add(_resultMap('asset-1'));
    await Future<void>.delayed(Duration.zero); // let the listener run

    expect(controller.items, hasLength(1));
    expect(controller.results['asset-1'], isNotNull);
    expect(controller.results['asset-1']!.isNsfw, isTrue);
    expect(notifyCount, greaterThan(0));

    await controller.dispose();
  });

  test('stopScan sets wasStopped=true', () async {
    final controller = NsfwScanController();
    await controller.startScan();
    expect(controller.isScanning, isTrue);

    await controller.stopScan();
    expect(controller.wasStopped, isTrue);
    expect(mock.cancelScanCalled, isTrue);

    await controller.dispose();
  });

  test('dispose cancels subs and notifyListeners after dispose is no-op',
      () async {
    final controller = NsfwScanController();
    await controller.startScan();

    // Snapshot listener count: dispose must not crash even when there's a
    // late event still queued from native.
    var calledAfterDispose = 0;
    controller.addListener(() => calledAfterDispose++);

    await controller.dispose();

    // Emit a stray event after dispose — must NOT throw and must NOT call
    // listeners (the controller swallows updates post-dispose).
    mock.scanEvents.add(_resultMap('asset-late'));
    await Future<void>.delayed(Duration.zero);

    expect(calledAfterDispose, 0,
        reason: 'listeners must not fire after dispose');
  });

  test('updateConfig swaps config and notifies', () async {
    final controller = NsfwScanController();
    var notifies = 0;
    controller.addListener(() => notifies++);

    const next = ScanConfiguration(confidenceThreshold: 0.42);
    controller.updateConfig(next);
    expect(controller.config.confidenceThreshold, 0.42);
    expect(notifies, 1);

    // Setting the same config again should not notify.
    controller.updateConfig(next);
    expect(notifies, 1);

    controller.dispose();
  });
}
