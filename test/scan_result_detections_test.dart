// Test fixtures use mutable map / list literals so they can be passed to
// `ScanResult.fromMap` which accepts `Map<dynamic, dynamic>`. The const-literal
// lint isn't useful here.
// ignore_for_file: prefer_const_literals_to_create_immutables

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('ScanResult.fromMap with detections', () {
    test('parses detection-mode payload into BodyPartDetection list', () {
      final result = ScanResult.fromMap({
        'localId': 'asset-1',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'labels': [
          {'category': 'nudity', 'confidence': 0.92},
          {'category': 'safe', 'confidence': 0.08},
        ],
        'detections': [
          {
            'label': 'FEMALE_BREAST_EXPOSED',
            'confidence': 0.92,
            'aggregatedCategory': 'nudity',
            'box': {'x': 0.1, 'y': 0.2, 'width': 0.3, 'height': 0.4},
          },
          {
            'label': 'FACE_FEMALE',
            'confidence': 0.7,
            'aggregatedCategory': 'safe',
            'box': {'x': 0.6, 'y': 0.0, 'width': 0.2, 'height': 0.2},
          },
        ],
      });
      expect(result.detections, isNotNull);
      expect(result.detections!.length, 2);
      expect(result.detections!.first.label, 'FEMALE_BREAST_EXPOSED');
      expect(result.detections!.first.aggregatedCategory, NsfwCategory.nudity);
      expect(result.topCategory, NsfwCategory.nudity);
    });

    test('classification payload yields null detections (BC)', () {
      final result = ScanResult.fromMap({
        'localId': 'asset-2',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'labels': [
          {'category': 'safe', 'confidence': 0.95},
        ],
      });
      expect(result.detections, isNull);
    });

    test('empty detections list normalises to null', () {
      final result = ScanResult.fromMap({
        'localId': 'asset-3',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'labels': const <Map<String, Object>>[],
        'detections': const <Map<String, Object>>[],
      });
      expect(result.detections, isNull);
    });

    test('toMap roundtrip preserves detections', () {
      final original = ScanResult.fromMap({
        'localId': 'asset-4',
        'mediaType': 'image',
        'status': 'completed',
        'scannedAt': 1700000000000,
        'labels': [
          {'category': 'explicitNudity', 'confidence': 0.88},
        ],
        'detections': [
          {
            'label': 'FEMALE_GENITALIA_EXPOSED',
            'confidence': 0.88,
            'aggregatedCategory': 'explicitNudity',
            'box': {'x': 0.4, 'y': 0.4, 'width': 0.1, 'height': 0.1},
          },
        ],
      });
      final restored = ScanResult.fromMap(original.toMap());
      expect(restored.detections, isNotNull);
      expect(restored.detections!.length, 1);
      expect(restored.detections!.first.label, 'FEMALE_GENITALIA_EXPOSED');
      expect(restored.detections!.first.aggregatedCategory,
          NsfwCategory.explicitNudity);
    });
  });

  group('ScanConfiguration.mode JSON', () {
    test('default mode is classification and round-trips', () {
      const config = ScanConfiguration();
      expect(config.mode, ScanMode.classification);
      final restored = ScanConfiguration.fromJson(config.toJson());
      expect(restored.mode, ScanMode.classification);
    });

    test('explicit detection mode round-trips', () {
      const config = ScanConfiguration(mode: ScanMode.detection);
      final json = config.toJson();
      expect(json['mode'], 'detection');
      final restored = ScanConfiguration.fromJson(json);
      expect(restored.mode, ScanMode.detection);
      expect(restored, config);
    });

    test('missing / unknown mode falls back to classification', () {
      final restored = ScanConfiguration.fromJson(
        const <String, dynamic>{'mode': 'banana'},
      );
      expect(restored.mode, ScanMode.classification);
      final restored2 =
          ScanConfiguration.fromJson(const <String, dynamic>{});
      expect(restored2.mode, ScanMode.classification);
    });

    test('copyWith updates mode', () {
      const a = ScanConfiguration();
      final b = a.copyWith(mode: ScanMode.detection);
      expect(b.mode, ScanMode.detection);
      expect(a.mode, ScanMode.classification);
      expect(a == b, isFalse);
    });
  });
}
