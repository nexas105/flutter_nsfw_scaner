import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('per-category thresholds — ScanResult.isNsfw', () {
    test('falls back to scalar when thresholdsByCategory is null', () {
      final r = ScanResult.fake(
        category: NsfwCategory.nudity,
        confidence: 0.8,
        confidenceThreshold: 0.7,
      );
      expect(r.isNsfw, isTrue);

      final low = r.withThresholds(null);
      expect(low.isNsfw, isTrue, reason: 'null map keeps scalar semantics');
    });

    test('explicit-strict + suggestive-tolerant', () {
      // Suggestive 0.9 should NOT flag at suggestive=0.95 cutoff.
      final suggestive = ScanResult.fake(
        category: NsfwCategory.suggestive,
        confidence: 0.9,
        confidenceThreshold: 0.7,
        thresholdsByCategory: const {
          NsfwCategory.explicitNudity: 0.5,
          NsfwCategory.nudity: 0.7,
          NsfwCategory.suggestive: 0.95,
        },
      );
      expect(suggestive.isNsfw, isFalse,
          reason: 'suggestive is not an NSFW category for isNsfw');

      // Explicit 0.6 SHOULD flag at explicit=0.5 cutoff.
      final explicit = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.6,
        confidenceThreshold: 0.9,
        thresholdsByCategory: const {
          NsfwCategory.explicitNudity: 0.5,
        },
      );
      expect(explicit.isNsfw, isTrue,
          reason: 'per-category 0.5 trumps scalar 0.9');
    });

    test('walks all NSFW labels — lower-priority match still flags', () {
      // Top label is suggestive @ 0.9 (sorted by category priority, then conf).
      // Explicit @ 0.6 sits later but should still flip isNsfw at threshold 0.5.
      final r = ScanResult.fake(
        confidenceThreshold: 0.9,
        thresholdsByCategory: const {
          NsfwCategory.explicitNudity: 0.5,
          NsfwCategory.suggestive: 0.95,
        },
        labels: const [
          NsfwLabel(category: NsfwCategory.explicitNudity, confidence: 0.6),
          NsfwLabel(category: NsfwCategory.suggestive, confidence: 0.9),
        ],
      );
      expect(r.isNsfw, isTrue);
    });

    test('missing category falls back to scalar', () {
      // explicitNudity at 0.8, scalar 0.7, no override for explicit → uses 0.7.
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.8,
        confidenceThreshold: 0.7,
        thresholdsByCategory: const {NsfwCategory.suggestive: 0.95},
      );
      expect(r.isNsfw, isTrue);
    });

    test('non-completed status never flags', () {
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.99,
        status: ScanStatus.failed,
        thresholdsByCategory: const {NsfwCategory.explicitNudity: 0.0},
      );
      expect(r.isNsfw, isFalse);
    });
  });

  group('per-category thresholds — category shortcuts', () {
    test('hasExplicitContent honors per-category override', () {
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.55,
        confidenceThreshold: 0.9,
        thresholdsByCategory: const {NsfwCategory.explicitNudity: 0.5},
      );
      expect(r.hasExplicitContent, isTrue);
      expect(r.hasNudity, isFalse);
    });

    test('isSuggestive ignores explicit threshold', () {
      final r = ScanResult.fake(
        confidenceThreshold: 0.7,
        thresholdsByCategory: const {
          NsfwCategory.suggestive: 0.9,
          NsfwCategory.explicitNudity: 0.3,
        },
        labels: const [
          NsfwLabel(category: NsfwCategory.suggestive, confidence: 0.85),
        ],
      );
      expect(r.isSuggestive, isFalse,
          reason: '0.85 < per-category 0.9');
    });
  });

  group('per-category thresholds — withThresholds + copyWith', () {
    test('withThresholds returns equal-label copy with new map', () {
      final base = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.6,
        confidenceThreshold: 0.9,
      );
      expect(base.isNsfw, isFalse);

      final tightened =
          base.withThresholds(const {NsfwCategory.explicitNudity: 0.5});
      expect(tightened.isNsfw, isTrue);
      expect(tightened.labels, equals(base.labels));
      expect(tightened.item.localIdentifier, base.item.localIdentifier);

      final cleared = tightened.withThresholds(null);
      expect(cleared.isNsfw, isFalse);
    });

    test('ScanConfiguration.copyWith carries thresholdsByCategory', () {
      const base = ScanConfiguration();
      final tight = base.copyWith(
        thresholdsByCategory: const {NsfwCategory.suggestive: 0.95},
      );
      expect(tight.thresholdsByCategory,
          equals({NsfwCategory.suggestive: 0.95}));
      expect(tight.confidenceThreshold, base.confidenceThreshold);
    });
  });

  group('per-category thresholds — JSON round-trip', () {
    test('ScanConfiguration round-trip preserves the map', () {
      const config = ScanConfiguration(
        thresholdsByCategory: {
          NsfwCategory.explicitNudity: 0.5,
          NsfwCategory.suggestive: 0.95,
        },
      );
      final json = config.toJson();
      expect(json['thresholdsByCategory'],
          equals({'explicitNudity': 0.5, 'suggestive': 0.95}));
      final restored = ScanConfiguration.fromJson(json);
      expect(restored.thresholdsByCategory,
          equals(config.thresholdsByCategory));
      expect(restored, equals(config));
      expect(restored.hashCode, equals(config.hashCode));
    });

    test('ScanResult round-trip preserves the map', () {
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.6,
        confidenceThreshold: 0.9,
        thresholdsByCategory: const {NsfwCategory.explicitNudity: 0.5},
      );
      final restored = ScanResult.fromJson(r.toJson());
      expect(restored.thresholdsByCategory,
          equals(r.thresholdsByCategory));
      expect(restored.isNsfw, isTrue);
    });

    test('unknown category names are dropped on parse', () {
      final restored = ScanConfiguration.fromJson(const {
        'thresholdsByCategory': <String, double>{
          'explicitNudity': 0.5,
          'bogus': 0.8,
        },
      });
      expect(restored.thresholdsByCategory,
          equals(const {NsfwCategory.explicitNudity: 0.5}));
    });

    test('out-of-range values are clamped on parse', () {
      final restored = ScanConfiguration.fromJson(const {
        'thresholdsByCategory': <String, double>{
          'explicitNudity': 1.5,
          'nudity': -0.3,
        },
      });
      expect(
          restored.thresholdsByCategory,
          equals(const {
            NsfwCategory.explicitNudity: 1.0,
            NsfwCategory.nudity: 0.0,
          }));
    });
  });
}
