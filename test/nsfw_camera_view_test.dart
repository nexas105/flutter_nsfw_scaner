import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Fake platform interface that lets a test push synthetic
/// `cameraFrameResult` / `cameraPermissionDenied` / `cameraError` events
/// into [NsfwCameraView] via [scanEventStream]. Mirrors the shape that
/// the iOS / Android native side emits.
class _FakeCameraPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  final scanEvents = StreamController<Map<dynamic, dynamic>>.broadcast();

  bool startCameraScanCalled = false;
  bool stopCameraScanCalled = false;
  CameraConfiguration? lastCameraConfig;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async =>
      PhotoLibraryPermissionStatus.authorized;
  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async =>
      PhotoLibraryPermissionStatus.authorized;
  @override
  Future<List<ModelDescriptor>> availableModels() async =>
      const [ModelDescriptor(id: 'm', displayName: 'M')];
  @override
  Future<void> startScan(ScanConfiguration config) async {}
  @override
  Future<void> cancelScan() async {}
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId, Map<String, double>? roi}) async =>
      {};

  @override
  Future<void> startCameraScan(CameraConfiguration config) async {
    startCameraScanCalled = true;
    lastCameraConfig = config;
  }

  @override
  Future<void> stopCameraScan() async {
    stopCameraScanCalled = true;
  }

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => scanEvents.stream;

  // Test helpers — push events as if they came from native.
  void emitFrame({
    required NsfwCategory category,
    double confidence = 0.95,
    List<Map<String, dynamic>>? detections,
    DateTime? frameTimestamp,
  }) {
    final ts = (frameTimestamp ?? DateTime.now()).millisecondsSinceEpoch;
    scanEvents.add({
      'type': 'cameraFrameResult',
      'frameTimestamp': ts,
      'scannedAt': ts,
      'labels': [
        {'category': category.name, 'confidence': confidence},
      ],
      if (detections != null) 'detections': detections,
    });
  }

  void emitPermissionDenied() {
    scanEvents.add({
      'type': 'cameraPermissionDenied',
      'message': 'Camera access denied',
    });
  }

  void emitError(String msg) {
    scanEvents.add({'type': 'cameraError', 'message': msg});
  }

  void dispose() => scanEvents.close();
}

void main() {
  late _FakeCameraPlatform fake;

  setUp(() {
    fake = _FakeCameraPlatform();
    NsfwPlatformInterface.instance = fake;
  });

  tearDown(() => fake.dispose());

  testWidgets('starts a camera scan on initState', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(config: CameraConfiguration()),
      ),
    ));
    // Allow the start future to resolve.
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(fake.startCameraScanCalled, isTrue);
  });

  testWidgets('stops the camera scan on dispose', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(config: CameraConfiguration()),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // Replace with empty scaffold — disposes the camera widget.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SizedBox.shrink()),
    ));
    await tester.pumpAndSettle();

    expect(fake.stopCameraScanCalled, isTrue);
  });

  testWidgets('forwards onResult callback for each frame', (tester) async {
    final received = <CameraFrameResult>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: const CameraConfiguration(),
          onResult: received.add,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.safe, confidence: 0.99);
    fake.emitFrame(category: NsfwCategory.nudity, confidence: 0.92);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(received.length, 2);
    expect(received[0].topCategory, NsfwCategory.safe);
    expect(received[1].topCategory, NsfwCategory.nudity);
    expect(received[1].topConfidence, closeTo(0.92, 0.0001));
  });

  testWidgets('renders HUD with confidence bar after first frame',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(config: CameraConfiguration()),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.nudity, confidence: 0.9);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.byType(NsfwCameraHud), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('hides HUD when showHudOverlay = false', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: CameraConfiguration(),
          showHudOverlay: false,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.nudity, confidence: 0.9);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(find.byType(NsfwCameraHud), findsNothing);
  });

  testWidgets('renders BackdropFilter blur layer when frame.isNsfw',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: CameraConfiguration(),
          enableBlurOnNsfw: true,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.nudity, confidence: 0.95);
    // Long enough for AnimatedSwitcher to settle.
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('does NOT render blur layer for safe frames', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: CameraConfiguration(),
          enableBlurOnNsfw: true,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.safe, confidence: 0.99);
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('routes cameraPermissionDenied to onPermissionDenied',
      (tester) async {
    var permissionFired = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: const CameraConfiguration(),
          onPermissionDenied: () => permissionFired++,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitPermissionDenied();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(permissionFired, 1);
  });

  testWidgets('routes cameraError to onError', (tester) async {
    final errors = <Object>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(
          config: const CameraConfiguration(),
          onError: errors.add,
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitError('boom');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(errors.length, 1);
    expect(errors.first, isA<CameraErrorException>());
  });

  testWidgets('renders detection overlay when detections present',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(config: CameraConfiguration()),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(
      category: NsfwCategory.nudity,
      confidence: 0.91,
      detections: [
        {
          'label': 'FEMALE_BREAST_EXPOSED',
          'confidence': 0.91,
          'aggregatedCategory': 'nudity',
          'box': {'x': 0.1, 'y': 0.1, 'width': 0.3, 'height': 0.3},
        },
      ],
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byType(NsfwDetectionOverlay), findsOneWidget);
  });

  testWidgets('renders without overflow in landscape (800x360)',
      (tester) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: NsfwCameraView(config: CameraConfiguration()),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    fake.emitFrame(category: NsfwCategory.nudity, confidence: 0.9);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });
}
