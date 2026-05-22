import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/src/api/nsfw_label.dart';
import 'package:nsfw_detect/src/platform/web/web_category_mapping.dart';

void main() {
  group('nsfwjsClassToCategory', () {
    test('maps the five nsfwjs classes to NsfwCategory', () {
      expect(nsfwjsClassToCategory('Neutral'), NsfwCategory.safe);
      expect(nsfwjsClassToCategory('Drawing'), NsfwCategory.safe);
      expect(nsfwjsClassToCategory('Sexy'), NsfwCategory.suggestive);
      expect(nsfwjsClassToCategory('Porn'), NsfwCategory.explicitNudity);
      expect(nsfwjsClassToCategory('Hentai'), NsfwCategory.explicitNudity);
    });

    test('is case- and whitespace-insensitive', () {
      expect(nsfwjsClassToCategory('  neutral '), NsfwCategory.safe);
      expect(nsfwjsClassToCategory('PORN'), NsfwCategory.explicitNudity);
    });

    test('unknown class names fall back to NsfwCategory.unknown', () {
      expect(nsfwjsClassToCategory('Spam'), NsfwCategory.unknown);
      expect(nsfwjsClassToCategory(''), NsfwCategory.unknown);
    });
  });

  group('aggregateNsfwjsPredictions', () {
    test('sums classes that share a category', () {
      final labels = aggregateNsfwjsPredictions({
        'Neutral': 0.5,
        'Drawing': 0.2,
        'Sexy': 0.1,
        'Porn': 0.15,
        'Hentai': 0.05,
      });
      final byCategory = {for (final l in labels) l.category: l.confidence};

      expect(byCategory[NsfwCategory.safe], closeTo(0.7, 1e-9));
      expect(byCategory[NsfwCategory.suggestive], closeTo(0.1, 1e-9));
      expect(byCategory[NsfwCategory.explicitNudity], closeTo(0.2, 1e-9));
      expect(byCategory.containsKey(NsfwCategory.nudity), isFalse);
    });

    test('result is sorted by confidence descending', () {
      final labels = aggregateNsfwjsPredictions({
        'Neutral': 0.1,
        'Porn': 0.8,
        'Sexy': 0.1,
      });
      expect(labels.first.category, NsfwCategory.explicitNudity);
      for (var i = 1; i < labels.length; i++) {
        expect(labels[i - 1].confidence >= labels[i].confidence, isTrue);
      }
    });

    test('ignores unknown class names instead of bucketing them', () {
      final labels = aggregateNsfwjsPredictions({
        'Neutral': 0.6,
        'Garbage': 0.4,
      });
      expect(labels.length, 1);
      expect(labels.single.category, NsfwCategory.safe);
      expect(labels.single.confidence, closeTo(0.6, 1e-9));
    });

    test('drops NaN and non-positive probabilities', () {
      final labels = aggregateNsfwjsPredictions({
        'Neutral': double.nan,
        'Sexy': 0.0,
        'Porn': -0.3,
        'Hentai': 0.5,
      });
      expect(labels.length, 1);
      expect(labels.single.category, NsfwCategory.explicitNudity);
      expect(labels.single.confidence, closeTo(0.5, 1e-9));
    });

    test('clamps an aggregated mass above 1.0', () {
      final labels = aggregateNsfwjsPredictions({
        'Neutral': 0.7,
        'Drawing': 0.6,
      });
      expect(labels.single.confidence, 1.0);
    });

    test('empty input yields no labels', () {
      expect(aggregateNsfwjsPredictions(const {}), isEmpty);
    });
  });
}
