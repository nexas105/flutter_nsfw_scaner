import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

import '_fakes/fake_nsfw_detector.dart';

void main() {
  late FakeNsfwPlatform fake;
  late List<TelemetryEvent> events;

  setUp(() {
    fake = FakeNsfwPlatform();
    NsfwPlatformInterface.instance = fake;
    events = <TelemetryEvent>[];
    NsfwDetector.instance.onTelemetryEvent = events.add;
    NsfwDetector.instance.includeLocalIdsInTelemetry = false;
  });

  tearDown(() {
    NsfwDetector.instance.onTelemetryEvent = null;
    NsfwDetector.instance.includeLocalIdsInTelemetry = false;
    fake.dispose();
  });

  group('confidenceBucketOf', () {
    test('buckets across [0, 1]', () {
      expect(confidenceBucketOf(0.0), 0);
      expect(confidenceBucketOf(0.05), 0);
      expect(confidenceBucketOf(0.5), 5);
      expect(confidenceBucketOf(0.99), 9);
      expect(confidenceBucketOf(1.0), 9);
    });

    test('rejects invalid input', () {
      expect(confidenceBucketOf(null), isNull);
      expect(confidenceBucketOf(double.nan), isNull);
      expect(confidenceBucketOf(-0.1), isNull);
    });
  });

  group('one-shot scans emit classifyTime', () {
    test('scanBytes emits with source=bytes and no localId', () async {
      fake.seedFrameResults([
        ScanResult.fake(
          category: NsfwCategory.explicitNudity,
          confidence: 0.88,
        ),
      ]);
      await NsfwDetector.instance.scanBytes(Uint8List.fromList([1, 2, 3]));
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.type, TelemetryEventType.classifyTime);
      expect(e.extras['source'], 'bytes');
      expect(e.topCategory, NsfwCategory.explicitNudity);
      expect(e.confidenceBucket, 8);
      expect(e.elapsed, isNotNull);
      expect(e.localId, isNull, reason: 'opt-in off by default');
    });

    test('scanAsset attaches localId only when opted in', () async {
      fake.results['asset-123'] =
          ScanResult.fake(localIdentifier: 'asset-123');
      NsfwDetector.instance.includeLocalIdsInTelemetry = true;
      await NsfwDetector.instance.scanAsset('asset-123');
      expect(events.single.localId, 'asset-123');
      expect(events.single.extras['source'], 'asset');
    });

    test('handler exception is swallowed', () async {
      NsfwDetector.instance.onTelemetryEvent =
          (_) => throw StateError('sink broke');
      // Should not throw — telemetry must never break scanning.
      await NsfwDetector.instance
          .scanBytes(Uint8List.fromList([1, 2, 3]));
    });

    test('no events when handler is null', () async {
      NsfwDetector.instance.onTelemetryEvent = null;
      await NsfwDetector.instance.scanBytes(Uint8List.fromList([4, 5]));
      expect(events, isEmpty);
    });
  });

  group('downloadModel emits started + finished', () {
    test('success path', () async {
      final ok = await NsfwDetector.instance.downloadModel('some-model');
      expect(ok, isTrue);
      expect(
        events.map((e) => e.type),
        containsAllInOrder(<TelemetryEventType>[
          TelemetryEventType.downloadStarted,
          TelemetryEventType.downloadFinished,
        ]),
      );
      final finished = events
          .lastWhere((e) => e.type == TelemetryEventType.downloadFinished);
      expect(finished.modelId, 'some-model');
      expect(finished.extras['ok'], true);
      expect(finished.elapsed, isNotNull);
    });

    test('throw path still emits finished with ok=false + errorMessage',
        () async {
      fake.downloadShouldFail = true;
      await expectLater(
        NsfwDetector.instance.downloadModel('bad-model'),
        throwsA(isA<StateError>()),
      );
      final finished = events
          .lastWhere((e) => e.type == TelemetryEventType.downloadFinished);
      expect(finished.extras['ok'], false);
      expect(finished.errorMessage, contains('simulated download failure'));
    });
  });

  group('preloadModel emits modelLoaded', () {
    test('success', () async {
      await NsfwDetector.instance.preloadModel('opennsfw2_coreml');
      final loaded = events.singleWhere(
        (e) => e.type == TelemetryEventType.modelLoaded,
      );
      expect(loaded.modelId, 'opennsfw2_coreml');
      expect(loaded.extras['ok'], true);
    });
  });

  group('TelemetryEvent factories', () {
    test('scanCompleted carries bucket + category', () {
      final e = TelemetryEvent.scanCompleted(
        modelId: 'm',
        topCategory: NsfwCategory.nudity,
        topConfidence: 0.42,
        fromCache: true,
        localId: 'x',
      );
      expect(e.confidenceBucket, 4);
      expect(e.topCategory, NsfwCategory.nudity);
      expect(e.fromCache, isTrue);
      expect(e.localId, 'x');
    });

    test('downloadProgress computes fraction', () {
      final e = TelemetryEvent.downloadProgress(
        modelId: 'm',
        downloadedBytes: 500,
        totalBytes: 2000,
      );
      expect(e.downloadFraction, closeTo(0.25, 1e-9));
    });

    test('downloadProgress fraction is null when total unknown', () {
      final e = TelemetryEvent.downloadProgress(
        modelId: 'm',
        downloadedBytes: 999,
      );
      expect(e.downloadFraction, isNull);
      expect(e.totalBytes, isNull);
    });
  });
}
