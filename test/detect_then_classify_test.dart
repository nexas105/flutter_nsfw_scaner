import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

import '_fakes/fake_nsfw_detector.dart';

Future<Uint8List> _synthPng({int width = 64, int height = 64}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF808080),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScanMode.detectThenClassify wire format', () {
    test('round-trips through wireValue / fromWire', () {
      expect(
        ScanMode.fromWire(ScanMode.detectThenClassify.wireValue),
        ScanMode.detectThenClassify,
      );
      expect(ScanMode.detectThenClassify.wireValue, 'detectThenClassify');
    });

    test('unknown / missing wire value falls back to classification', () {
      expect(ScanMode.fromWire('bogus'), ScanMode.classification);
      expect(ScanMode.fromWire(null), ScanMode.classification);
    });
  });

  group('BodyPartDetection.labels', () {
    test('round-trips through toMap / fromMap', () {
      const det = BodyPartDetection(
        label: 'FEMALE_BREAST_EXPOSED',
        confidence: 0.88,
        box: BoundingBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        aggregatedCategory: NsfwCategory.nudity,
        labels: [
          NsfwLabel(category: NsfwCategory.nudity, confidence: 0.92),
          NsfwLabel(category: NsfwCategory.suggestive, confidence: 0.05),
          NsfwLabel(category: NsfwCategory.safe, confidence: 0.03),
        ],
      );
      final restored = BodyPartDetection.fromMap(det.toMap());
      expect(restored, equals(det));
      expect(restored.labels, isNotNull);
      expect(restored.labels, hasLength(3));
      expect(restored.labels!.first.confidence, closeTo(0.92, 1e-9));
    });

    test('absent labels stays null after round-trip', () {
      const det = BodyPartDetection(
        label: 'FACE_FEMALE',
        confidence: 0.6,
        box: BoundingBox(x: 0, y: 0, width: 1, height: 1),
        aggregatedCategory: NsfwCategory.safe,
      );
      final restored = BodyPartDetection.fromMap(det.toMap());
      expect(restored.labels, isNull);
    });

    test('equality + hashCode distinguish different label lists', () {
      const labelsA = [
        NsfwLabel(category: NsfwCategory.nudity, confidence: 0.9),
      ];
      const labelsB = [
        NsfwLabel(category: NsfwCategory.suggestive, confidence: 0.9),
      ];
      const a = BodyPartDetection(
        label: 'X',
        confidence: 0.5,
        box: BoundingBox(x: 0, y: 0, width: 0.5, height: 0.5),
        aggregatedCategory: NsfwCategory.nudity,
        labels: labelsA,
      );
      const b = BodyPartDetection(
        label: 'X',
        confidence: 0.5,
        box: BoundingBox(x: 0, y: 0, width: 0.5, height: 0.5),
        aggregatedCategory: NsfwCategory.nudity,
        labels: labelsB,
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(b.hashCode));
    });
  });

  group('scanBytesDetectThenClassify pipeline', () {
    late FakeNsfwPlatform fake;

    setUp(() {
      fake = FakeNsfwPlatform();
      NsfwPlatformInterface.instance = fake;
    });

    tearDown(() => fake.dispose());

    test('attaches classifier labels per detection box', () async {
      // Detector returns one box; classifier returns nudity@0.9.
      final detectorResult = ScanResult(
        item: const MediaItem(localIdentifier: 'pipe', type: MediaType.image),
        status: ScanStatus.completed,
        labels: const [
          NsfwLabel(category: NsfwCategory.nudity, confidence: 0.7),
        ],
        scannedAt: DateTime.now(),
        confidenceThreshold: 0.7,
        detections: const [
          BodyPartDetection(
            label: 'FEMALE_BREAST_EXPOSED',
            confidence: 0.8,
            box: BoundingBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            aggregatedCategory: NsfwCategory.nudity,
          ),
        ],
      );
      final classifierResult = ScanResult.fake(
        category: NsfwCategory.nudity,
        confidence: 0.9,
      );
      // First call is the detector pass, the next is the per-crop classifier.
      fake.seedFrameResults([detectorResult, classifierResult]);

      final png = await _synthPng();
      final result = await NsfwDetector.instance.scanBytesDetectThenClassify(
        png,
        detectorModelId: 'nudenet',
        classifierModelId: ModelIds.openNsfw2,
      );

      expect(result.detections, hasLength(1));
      final enriched = result.detections!.single;
      expect(enriched.labels, isNotNull);
      expect(enriched.labels!.single.category, NsfwCategory.nudity);
      expect(enriched.labels!.single.confidence, closeTo(0.9, 1e-9));
    });

    test('returns detector result unchanged when no detections', () async {
      final detectorResult = ScanResult.fake(
        category: NsfwCategory.safe,
        confidence: 0.99,
      );
      fake.seedFrameResults([detectorResult]);

      final png = await _synthPng();
      final result = await NsfwDetector.instance.scanBytesDetectThenClassify(
        png,
        detectorModelId: 'nudenet',
      );
      expect(result.detections, isNull);
      // We invoked scanBytes exactly once — no second-pass classifier call.
      expect(
        fake.calls.where((c) => c.method == 'scanImageBytes').length,
        1,
      );
    });
  });
}
