import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

// ---------------------------------------------------------------------------
// Mock platform
// ---------------------------------------------------------------------------
class MockNsfwPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  PhotoLibraryPermissionStatus permissionStatus =
      PhotoLibraryPermissionStatus.authorized;

  final scanEventsController =
      StreamController<Map<dynamic, dynamic>>.broadcast();

  bool startScanCalled = false;
  bool cancelScanCalled = false;
  bool resetScanCalled = false;
  String? lastPreloadModelId;

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async =>
      permissionStatus;

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async =>
      permissionStatus;

  @override
  Future<List<ModelDescriptor>> availableModels() async => [
        const ModelDescriptor(id: 'test_model', displayName: 'Test Model'),
      ];

  @override
  Future<void> preloadModel(String modelId) async {
    lastPreloadModelId = modelId;
  }

  @override
  Future<void> startScan(ScanConfiguration config) async {
    startScanCalled = true;
  }

  @override
  Future<void> cancelScan() async {
    cancelScanCalled = true;
  }

  @override
  Future<void> resetScan() async {
    resetScanCalled = true;
  }

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId}) async {
    return {
      'localId': localIdentifier,
      'mediaType': 'image',
      'status': 'completed',
      'scannedAt': DateTime.now().millisecondsSinceEpoch,
      'labels': [
        {'category': 'safe', 'confidence': 0.95},
        {'category': 'nudity', 'confidence': 0.03},
      ],
    };
  }

  @override
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems) async {}

  @override
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
          {String? modelId}) async =>
      {
        'localId': filePath,
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': [
          {'category': 'safe', 'confidence': 0.95},
        ],
      };

  @override
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
          {String? modelId}) async =>
      {
        'localId': 'bytes_test',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': [
          {'category': 'safe', 'confidence': 0.95},
        ],
      };

  @override
  Future<bool> downloadModel(String modelId, {String? url}) async => true;

  @override
  Future<void> deleteModel(String modelId) async {}

  @override
  Future<void> setModelUrl(String modelId, String url) async {}

  @override
  Future<void> setLogging(bool enabled) async {}

  @override
  Future<void> clearScanCache({String? modelId}) async {}

  @override
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) async =>
      const [];

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      scanEventsController.stream;

  void dispose() => scanEventsController.close();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
void main() {
  group('NsfwLabel', () {
    test('fromMap parses correctly', () {
      final label =
          NsfwLabel.fromMap(const {'category': 'nudity', 'confidence': 0.92});
      expect(label.category, NsfwCategory.nudity);
      expect(label.confidence, 0.92);
    });

    test('unknown category maps to NsfwCategory.unknown', () {
      final label =
          NsfwLabel.fromMap(const {'category': 'banana', 'confidence': 0.5});
      expect(label.category, NsfwCategory.unknown);
    });

    test('toMap round-trips', () {
      const label = NsfwLabel(category: NsfwCategory.safe, confidence: 0.88);
      final map = label.toMap();
      final restored = NsfwLabel.fromMap(map);
      expect(restored, label);
    });

    test('isNsfw on categories', () {
      expect(NsfwCategory.safe.isNsfw, false);
      expect(NsfwCategory.suggestive.isNsfw, false);
      expect(NsfwCategory.nudity.isNsfw, true);
      expect(NsfwCategory.explicitNudity.isNsfw, true);
    });
  });

  group('ScanResult', () {
    test('isNsfw respects threshold', () {
      final nsfwResult = ScanResult.fromMap({
        'localId': 'abc',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': const [
          {'category': 'nudity', 'confidence': 0.85},
          {'category': 'safe', 'confidence': 0.15},
        ],
      }, confidenceThreshold: 0.7);
      expect(nsfwResult.isNsfw, true);
      expect(nsfwResult.topCategory, NsfwCategory.nudity);
    });

    test('isNsfw false when below threshold', () {
      final borderline = ScanResult.fromMap({
        'localId': 'abc',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': const [
          {'category': 'nudity', 'confidence': 0.5},
          {'category': 'safe', 'confidence': 0.5},
        ],
      }, confidenceThreshold: 0.7);
      expect(borderline.isNsfw, false);
    });

    test('failed status is not NSFW', () {
      final failed = ScanResult.fromMap({
        'localId': 'abc',
        'mediaType': 'image',
        'status': 'failed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': const [],
        'errorMessage': 'timeout',
      }, confidenceThreshold: 0.7);
      expect(failed.isNsfw, false);
      expect(failed.status, ScanStatus.failed);
    });

    test('labels sorted by confidence descending', () {
      final result = ScanResult.fromMap({
        'localId': 'abc',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': const [
          {'category': 'safe', 'confidence': 0.1},
          {'category': 'nudity', 'confidence': 0.9},
        ],
      }, confidenceThreshold: 0.7);
      expect(result.labels.first.category, NsfwCategory.nudity);
      expect(result.labels.last.category, NsfwCategory.safe);
    });
  });

  group('MediaItem', () {
    test('fromMap with all fields', () {
      final item = MediaItem.fromMap(const {
        'localId': 'photo-123',
        'mediaType': 'video',
        'creationDate': 1700000000000,
        'durationMs': 5000,
        'width': 1920,
        'height': 1080,
      });
      expect(item.localIdentifier, 'photo-123');
      expect(item.type, MediaType.video);
      expect(item.duration, const Duration(seconds: 5));
      expect(item.width, 1920);
    });

    test('equality by localIdentifier', () {
      const a = MediaItem(localIdentifier: 'x', type: MediaType.image);
      const b = MediaItem(localIdentifier: 'x', type: MediaType.video);
      expect(a, b); // same ID = same item
    });
  });

  group('ScanProgress', () {
    test('fraction calculation', () {
      final p = ScanProgress.fromMap(const {
        'scannedCount': 25,
        'totalCount': 100,
        'isComplete': false,
      });
      expect(p.fraction, 0.25);
    });

    test('zero total returns 0 fraction', () {
      final p = ScanProgress.fromMap(const {
        'scannedCount': 0,
        'totalCount': 0,
        'isComplete': true,
      });
      expect(p.fraction, 0.0);
    });
  });

  group('ScanConfiguration', () {
    test('defaults', () {
      const c = ScanConfiguration();
      expect(c.confidenceThreshold, 0.7);
      expect(c.maxVideoFrames, 8);
      expect(c.includeVideos, true);
    });

    test('copyWith preserves unchanged values', () {
      const original = ScanConfiguration(confidenceThreshold: 0.9);
      final copy = original.copyWith(maxVideoFrames: 4);
      expect(copy.confidenceThreshold, 0.9);
      expect(copy.maxVideoFrames, 4);
    });
  });

  group('NsfwDetector (with mock platform)', () {
    late MockNsfwPlatform mock;

    setUp(() {
      mock = MockNsfwPlatform();
      NsfwPlatformInterface.instance = mock;
    });

    tearDown(() => mock.dispose());

    test('checkPermission delegates to platform', () async {
      mock.permissionStatus = PhotoLibraryPermissionStatus.limited;
      final status = await NsfwDetector.instance.checkPermission();
      expect(status, PhotoLibraryPermissionStatus.limited);
    });

    test('availableModels returns list', () async {
      final models = await NsfwDetector.instance.availableModels();
      expect(models, hasLength(1));
      expect(models.first.id, 'test_model');
    });

    test('preloadModel calls platform', () async {
      await NsfwDetector.instance.preloadModel('test_model');
      expect(mock.lastPreloadModelId, 'test_model');
    });

    test('scanAsset returns result', () async {
      final result = await NsfwDetector.instance.scanAsset('photo-1');
      expect(result.item.localIdentifier, 'photo-1');
      expect(result.topCategory, NsfwCategory.safe);
      expect(result.isNsfw, false);
    });

    test('startScan creates session and calls platform', () async {
      const config = ScanConfiguration();
      final session = await NsfwDetector.instance.startScan(config);
      expect(mock.startScanCalled, true);
      expect(session.isRunning, true);

      // Emit a result event
      mock.scanEventsController.add({
        'type': 'result',
        'localId': 'img-1',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': DateTime.now().millisecondsSinceEpoch,
        'labels': [
          {'category': 'nudity', 'confidence': 0.95},
        ],
      });

      final result = await session.results.first;
      expect(result.isNsfw, true);

      // Emit progress complete
      mock.scanEventsController.add({
        'type': 'progress',
        'scannedCount': 1,
        'totalCount': 1,
        'isComplete': true,
      });

      final summary = await session.done;
      expect(summary.nsfwCount, 1);
      expect(summary.totalScanned, 1);
    });

    test('resetScan delegates to platform', () async {
      await NsfwDetector.instance.resetScan();
      expect(mock.resetScanCalled, true);
    });
  });
}
