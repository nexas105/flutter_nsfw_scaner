import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _CapturePlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  final scanEventsController =
      StreamController<Map<dynamic, dynamic>>.broadcast();

  Uint8List? lastScanBytes;
  Map<dynamic, dynamic>? cachedResultPayload;
  List<String>? lastPrefetchIds;
  Uint8List redactedBytesResponse = Uint8List.fromList([1, 2, 3]);
  String redactedFileResponse = '/tmp/redacted.jpg';
  List<Map<String, Object?>>? lastRedactBytesDetections;
  String? lastRedactMode;
  double? lastRedactIntensity;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async =>
      PhotoLibraryPermissionStatus.authorized;
  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async =>
      PhotoLibraryPermissionStatus.authorized;
  @override
  Future<List<ModelDescriptor>> availableModels() async => const [];
  @override
  Future<void> startScan(ScanConfiguration config) async {}
  @override
  Future<void> cancelScan() async {}
  @override
  Future<void> startCameraScan(CameraConfiguration config) async {}
  @override
  Future<void> stopCameraScan() async {}

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId, Map<String, double>? roi}) async => {
        'localId': localIdentifier,
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': const [
          {'category': 'safe', 'confidence': 0.9},
        ],
      };

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
      {String? modelId, Map<String, double>? roi}) async {
    lastScanBytes = bytes;
    return {
      'localId': 'memory://${bytes.length}',
      'mediaType': 'image',
      'status': 'completed',
      'scannedAt': DateTime.now().millisecondsSinceEpoch,
      'labels': const [
        {'category': 'safe', 'confidence': 0.9},
      ],
    };
  }

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      scanEventsController.stream;

  @override
  Future<Map<dynamic, dynamic>?> cachedResult(
    String localIdentifier, {
    String? modelId,
  }) async =>
      cachedResultPayload;

  @override
  Future<void> prefetchAssets(
    List<String> localIdentifiers, {
    String? modelId,
  }) async {
    lastPrefetchIds = localIdentifiers;
  }

  @override
  Future<Uint8List> redactBytes({
    required Uint8List bytes,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputFormat,
  }) async {
    lastRedactBytesDetections = detections;
    lastRedactMode = mode;
    lastRedactIntensity = intensity;
    return redactedBytesResponse;
  }

  @override
  Future<String> redactFile({
    required String inputPath,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputPath,
  }) async =>
      redactedFileResponse;

  void dispose() => scanEventsController.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CapturePlatform platform;

  setUp(() {
    platform = _CapturePlatform();
    NsfwPlatformInterface.instance = platform;
  });

  tearDown(() => platform.dispose());

  // Note: scanImageProvider's resolve → encode → scanBytes path is exercised
  // by an integration test rather than a unit test — feeding the Flutter
  // image pipeline a synthetic decoded image from inside flutter_test is
  // fragile and platform-codec dependent.

  group('scanUrl', () {
    test('rejects non-http(s) schemes synchronously via ArgumentError',
        () async {
      await expectLater(
        () => NsfwDetector.instance.scanUrl(Uri.parse('file:///etc/passwd')),
        throwsArgumentError,
      );
    });
  });

  group('cachedResult', () {
    test('returns null when the cache has no entry', () async {
      platform.cachedResultPayload = null;
      final result = await NsfwDetector.instance.cachedResult('local://1');
      expect(result, isNull);
    });

    test('builds a ScanResult with fromCache flag set', () async {
      platform.cachedResultPayload = {
        'localId': 'local://42',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'fromCache': true,
        'labels': const [
          {'category': 'nudity', 'confidence': 0.83},
        ],
      };
      final result = await NsfwDetector.instance.cachedResult(
        'local://42',
        confidenceThreshold: 0.7,
      );
      expect(result, isNotNull);
      expect(result!.fromCache, true);
      expect(result.topCategory, NsfwCategory.nudity);
      expect(result.isNsfw, true);
    });
  });

  group('cacheUpdates stream', () {
    test('only emits result-type events as ScanResult', () async {
      final results = <ScanResult>[];
      final sub = NsfwDetector.instance.cacheUpdates.listen(results.add);
      // Not a result event — should be filtered out.
      platform.scanEventsController.add({'type': 'progress', 'scanned': 1});
      platform.scanEventsController.add({
        'type': 'result',
        'localId': 'x',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'labels': const [
          {'category': 'safe', 'confidence': 0.99},
        ],
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(results, hasLength(1));
      expect(results.single.item.localIdentifier, 'x');
    });
  });

  group('prefetchAssets', () {
    test('forwards the id list to the platform', () async {
      await NsfwDetector.instance.prefetchAssets(['a', 'b', 'c']);
      expect(platform.lastPrefetchIds, ['a', 'b', 'c']);
    });
  });

  group('redactBytes / redactFile', () {
    test('clamps intensity into [0, 1] before the channel call', () async {
      await NsfwDetector.instance.redactBytes(
        Uint8List(0),
        ScanResult.fake(category: NsfwCategory.nudity, confidence: 0.9),
        intensity: 1.7,
      );
      expect(platform.lastRedactIntensity, 1.0);
    });

    test('passes the chosen mode as its wire value', () async {
      await NsfwDetector.instance.redactBytes(
        Uint8List(0),
        ScanResult.fake(category: NsfwCategory.nudity, confidence: 0.9),
        mode: RedactionMode.pixelate,
        intensity: 0.5,
      );
      expect(platform.lastRedactMode, 'pixelate');
    });

    test('returns the platform-provided bytes', () async {
      platform.redactedBytesResponse = Uint8List.fromList([9, 8, 7]);
      final out = await NsfwDetector.instance.redactBytes(
        Uint8List(0),
        ScanResult.fake(category: NsfwCategory.nudity, confidence: 0.9),
      );
      expect(out, [9, 8, 7]);
    });
  });

  group('RedactionMode', () {
    test('wireValue mapping is stable', () {
      expect(RedactionMode.blur.wireValue, 'blur');
      expect(RedactionMode.pixelate.wireValue, 'pixelate');
      expect(RedactionMode.blackBox.wireValue, 'blackBox');
    });

    test('fromString defaults to blur for unknown input', () {
      expect(RedactionMode.fromString(null), RedactionMode.blur);
      expect(RedactionMode.fromString('bogus'), RedactionMode.blur);
      expect(RedactionMode.fromString('blackBox'), RedactionMode.blackBox);
    });
  });
}
