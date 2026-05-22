/// Translates the nsfwjs 5-class taxonomy into the plugin's [NsfwCategory]
/// model. Pure Dart, no `dart:js_interop` / `package:web` dependency, so it
/// runs and is unit-testable on every platform.
///
/// nsfwjs (https://github.com/infinitered/nsfwjs) emits a softmax over five
/// mutually-exclusive classes:
///
///   | nsfwjs class | NsfwCategory                |
///   |--------------|-----------------------------|
///   | `Neutral`    | [NsfwCategory.safe]         |
///   | `Drawing`    | [NsfwCategory.safe]         |
///   | `Sexy`       | [NsfwCategory.suggestive]   |
///   | `Porn`       | [NsfwCategory.explicitNudity] |
///   | `Hentai`     | [NsfwCategory.explicitNudity] |
///
/// nsfwjs has no separate "exposed but not explicit" class, so
/// [NsfwCategory.nudity] is never produced by the web classifier — explicit
/// content collapses straight into [NsfwCategory.explicitNudity]. Callers that
/// branch on `nudity` vs `explicitNudity` should treat the web platform as
/// reporting only the latter.
library;

import '../../api/nsfw_label.dart';

/// Maps a single raw nsfwjs class name to a [NsfwCategory]. Case-insensitive;
/// unknown names fall back to [NsfwCategory.unknown].
NsfwCategory nsfwjsClassToCategory(String className) {
  switch (className.trim().toLowerCase()) {
    case 'neutral':
    case 'drawing':
      return NsfwCategory.safe;
    case 'sexy':
      return NsfwCategory.suggestive;
    case 'porn':
    case 'hentai':
      return NsfwCategory.explicitNudity;
    default:
      return NsfwCategory.unknown;
  }
}

/// Aggregates a raw `{className: probability}` map from `model.classify()`
/// into the plugin's [NsfwLabel] list.
///
/// Because the nsfwjs classes are mutually-exclusive softmax outputs, classes
/// that share a [NsfwCategory] have their probabilities **summed** — e.g.
/// `P(safe) = P(Neutral) + P(Drawing)`. The result is a proper probability
/// distribution over [NsfwCategory], so `ScanResult.topConfidence` stays
/// comparable to the native classifier's scalar score.
///
/// Output is sorted by confidence descending. Categories with zero mass are
/// omitted. Unknown class names are ignored rather than bucketed into
/// [NsfwCategory.unknown], so a typo in the model output cannot manufacture a
/// spurious label.
List<NsfwLabel> aggregateNsfwjsPredictions(Map<String, double> rawProbs) {
  final byCategory = <NsfwCategory, double>{};
  for (final entry in rawProbs.entries) {
    final category = nsfwjsClassToCategory(entry.key);
    if (category == NsfwCategory.unknown) continue;
    final p = entry.value;
    if (p.isNaN || p <= 0) continue;
    byCategory[category] = (byCategory[category] ?? 0) + p;
  }

  final labels = byCategory.entries
      .map((e) => NsfwLabel(
            category: e.key,
            confidence: e.value.clamp(0.0, 1.0),
          ))
      .toList()
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  return labels;
}
