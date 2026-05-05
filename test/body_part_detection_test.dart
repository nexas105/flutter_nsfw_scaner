import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('BodyPartDetection.aggregateCategoryFromLabel', () {
    // The 18 NudeNet classes — expectations match the canonical mapping in
    // BodyPartDetection.aggregateCategoryFromLabel and must stay in lock-step
    // with the iOS / Android native helpers.
    const explicit = {
      'FEMALE_GENITALIA_EXPOSED',
      'MALE_GENITALIA_EXPOSED',
      'ANUS_EXPOSED',
    };
    const nudity = {
      'FEMALE_BREAST_EXPOSED',
      'MALE_BREAST_EXPOSED',
      'BUTTOCKS_EXPOSED',
    };
    const suggestive = {
      'FEMALE_GENITALIA_COVERED',
      'FEMALE_BREAST_COVERED',
      'BUTTOCKS_COVERED',
      'ANUS_COVERED',
    };
    const safe = {
      'FACE_FEMALE',
      'FACE_MALE',
      'FEET_EXPOSED',
      'FEET_COVERED',
      'BELLY_EXPOSED',
      'BELLY_COVERED',
      'ARMPITS_EXPOSED',
      'ARMPITS_COVERED',
    };

    test('explicit nudity bucket', () {
      for (final label in explicit) {
        expect(
          BodyPartDetection.aggregateCategoryFromLabel(label),
          NsfwCategory.explicitNudity,
          reason: label,
        );
      }
    });

    test('nudity bucket', () {
      for (final label in nudity) {
        expect(
          BodyPartDetection.aggregateCategoryFromLabel(label),
          NsfwCategory.nudity,
          reason: label,
        );
      }
    });

    test('suggestive bucket', () {
      for (final label in suggestive) {
        expect(
          BodyPartDetection.aggregateCategoryFromLabel(label),
          NsfwCategory.suggestive,
          reason: label,
        );
      }
    });

    test('safe bucket', () {
      for (final label in safe) {
        expect(
          BodyPartDetection.aggregateCategoryFromLabel(label),
          NsfwCategory.safe,
          reason: label,
        );
      }
    });

    test('unknown labels fall back to NsfwCategory.unknown', () {
      expect(
        BodyPartDetection.aggregateCategoryFromLabel('SOME_OTHER_THING'),
        NsfwCategory.unknown,
      );
      expect(
        BodyPartDetection.aggregateCategoryFromLabel(''),
        NsfwCategory.unknown,
      );
    });

    test('mapping is case-insensitive on input', () {
      expect(
        BodyPartDetection.aggregateCategoryFromLabel('female_breast_exposed'),
        NsfwCategory.nudity,
      );
      expect(
        BodyPartDetection.aggregateCategoryFromLabel('  Anus_Exposed  '),
        NsfwCategory.explicitNudity,
      );
    });

    test('all 18 NudeNet labels are bucketed (none falls through)', () {
      final all = <String>{...explicit, ...nudity, ...suggestive, ...safe};
      expect(all.length, 18);
      for (final label in all) {
        expect(
          BodyPartDetection.aggregateCategoryFromLabel(label),
          isNot(NsfwCategory.unknown),
          reason: label,
        );
      }
    });
  });

  group('BoundingBox', () {
    test('toMap / fromMap roundtrip', () {
      const box = BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4);
      final restored = BoundingBox.fromMap(box.toMap());
      expect(restored, box);
      expect(restored.hashCode, box.hashCode);
    });

    test('fromMap clamps to [0, 1]', () {
      final box = BoundingBox.fromMap(
        const {'x': -0.5, 'y': 1.5, 'width': 2.0, 'height': 0.3},
      );
      expect(box.x, 0.0);
      expect(box.y, 1.0);
      expect(box.width, 1.0);
      expect(box.height, 0.3);
    });

    test('fromMap defaults missing / non-numeric fields to 0', () {
      final box = BoundingBox.fromMap(const {'x': 0.5});
      expect(box.x, 0.5);
      expect(box.y, 0.0);
      expect(box.width, 0.0);
      expect(box.height, 0.0);
    });
  });

  group('BodyPartDetection.fromMap', () {
    test('parses canonical wire shape', () {
      final det = BodyPartDetection.fromMap(const {
        'label': 'FEMALE_BREAST_EXPOSED',
        'confidence': 0.92,
        'aggregatedCategory': 'nudity',
        'box': {'x': 0.1, 'y': 0.2, 'width': 0.3, 'height': 0.4},
      });
      expect(det.label, 'FEMALE_BREAST_EXPOSED');
      expect(det.confidence, closeTo(0.92, 1e-6));
      expect(det.aggregatedCategory, NsfwCategory.nudity);
      expect(det.box.x, 0.1);
    });

    test('falls back to label-derived category when key missing', () {
      final det = BodyPartDetection.fromMap(const {
        'label': 'FEMALE_GENITALIA_EXPOSED',
        'confidence': 0.85,
        'box': {'x': 0.0, 'y': 0.0, 'width': 0.5, 'height': 0.5},
      });
      expect(det.aggregatedCategory, NsfwCategory.explicitNudity);
    });

    test('falls back to flattened x/y/w/h when box missing', () {
      final det = BodyPartDetection.fromMap(const {
        'label': 'FACE_FEMALE',
        'confidence': 0.7,
        'x': 0.1,
        'y': 0.2,
        'width': 0.3,
        'height': 0.4,
      });
      expect(det.box.x, 0.1);
      expect(det.box.height, 0.4);
    });

    test('toMap roundtrip preserves all fields', () {
      const det = BodyPartDetection(
        label: 'BUTTOCKS_COVERED',
        confidence: 0.55,
        box: BoundingBox(x: 0.2, y: 0.3, width: 0.4, height: 0.5),
        aggregatedCategory: NsfwCategory.suggestive,
      );
      final restored = BodyPartDetection.fromMap(det.toMap());
      expect(restored, det);
    });
  });
}
