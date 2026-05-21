import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('ScanConfiguration presets', () {
    test('strict uses 0.85 threshold and default model', () {
      const cfg = ScanConfiguration.strict();
      expect(cfg.confidenceThreshold, 0.85);
      expect(cfg.modelId, ModelIds.openNsfw2);
      expect(cfg.includeVideos, isTrue);
    });

    test('moderate matches the default constructor on threshold', () {
      const preset = ScanConfiguration.moderate();
      const base = ScanConfiguration();
      expect(preset.confidenceThreshold, base.confidenceThreshold);
    });

    test('permissive uses 0.5 threshold', () {
      const cfg = ScanConfiguration.permissive();
      expect(cfg.confidenceThreshold, 0.5);
    });

    test('fastScan bumps concurrency to 8', () {
      const cfg = ScanConfiguration.fastScan();
      expect(cfg.concurrency, 8);
      expect(cfg.skipAlreadyScanned, isTrue);
    });

    test('presets accept overrides', () {
      const cfg = ScanConfiguration.strict(
        modelId: ModelIds.adamcodd,
        includeVideos: false,
      );
      expect(cfg.modelId, ModelIds.adamcodd);
      expect(cfg.includeVideos, isFalse);
      expect(cfg.confidenceThreshold, 0.85);
    });
  });

  group('CameraConfiguration presets', () {
    test('realtime → 10 FPS high', () {
      const cfg = CameraConfiguration.realtime();
      expect(cfg.fps, 10);
      expect(cfg.resolution, CameraResolution.high);
    });

    test('balanced matches default', () {
      const preset = CameraConfiguration.balanced();
      const base = CameraConfiguration();
      expect(preset.fps, base.fps);
      expect(preset.resolution, base.resolution);
    });

    test('batteryEfficient → 1 FPS low', () {
      const cfg = CameraConfiguration.batteryEfficient();
      expect(cfg.fps, 1);
      expect(cfg.resolution, CameraResolution.low);
    });
  });
}
