import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('ScanConfiguration JSON', () {
    test('default config round-trips', () {
      const original = ScanConfiguration();
      final restored = ScanConfiguration.fromJson(original.toJson());
      expect(restored, original);
    });

    test('non-default config round-trips', () {
      const original = ScanConfiguration(
        modelId: ModelIds.adamcodd,
        confidenceThreshold: 0.85,
        maxVideoFrames: 12,
        videoFrameInterval: 1.5,
        includeVideos: false,
        includeLivePhotos: false,
        resumeFromCheckpoint: true,
        concurrency: 6,
        detectionConfidenceThreshold: 0.3,
        iouThreshold: 0.5,
        disableBatchPrediction: true,
        skipAlreadyScanned: false,
        forceRescan: true,
        replayCachedResults: false,
        iosComputeUnits: IosComputeUnits.cpuOnly,
        androidDelegate: AndroidDelegate.gpu,
        assetIdentifiers: ['a', 'b'],
      );
      final restored = ScanConfiguration.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.hashCode, original.hashCode);
    });

    test('fromJson tolerates missing fields by using defaults', () {
      final restored =
          ScanConfiguration.fromJson(const <String, dynamic>{'modelId': 'x'});
      expect(restored.modelId, 'x');
      expect(restored.confidenceThreshold, 0.7);
      expect(restored.includeVideos, true);
    });

    test('fromJson rejects unknown enum strings gracefully', () {
      final restored = ScanConfiguration.fromJson(const {
        'iosComputeUnits': 'banana',
        'androidDelegate': 'banana',
      });
      expect(restored.iosComputeUnits, IosComputeUnits.all);
      expect(restored.androidDelegate, isNull);
    });

    test('equality is value-based', () {
      const a = ScanConfiguration(confidenceThreshold: 0.8);
      const b = ScanConfiguration(confidenceThreshold: 0.8);
      const c = ScanConfiguration(confidenceThreshold: 0.9);
      expect(a, b);
      expect(a == c, false);
    });
  });
}
