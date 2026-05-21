import 'package:nsfw_detect/nsfw_detect.dart';

/// Per-category precision / recall / F1 / support tallied across an eval run.
///
/// Maths uses the standard binary "is this category" framing per category:
///
///   precision = TP / (TP + FP)
///   recall    = TP / (TP + FN)
///   F1        = 2 * P * R / (P + R)
///
/// Support is the number of ground-truth items in that category.
class CategoryMetrics {
  final NsfwCategory category;
  final int truePositive;
  final int falsePositive;
  final int falseNegative;
  final int support;

  const CategoryMetrics({
    required this.category,
    required this.truePositive,
    required this.falsePositive,
    required this.falseNegative,
    required this.support,
  });

  double get precision =>
      (truePositive + falsePositive) == 0
          ? 0.0
          : truePositive / (truePositive + falsePositive);

  double get recall =>
      (truePositive + falseNegative) == 0
          ? 0.0
          : truePositive / (truePositive + falseNegative);

  double get f1 {
    final p = precision;
    final r = recall;
    final denom = p + r;
    return denom == 0 ? 0.0 : 2 * p * r / denom;
  }

  Map<String, Object?> toJson() => {
        'category': category.name,
        'support': support,
        'truePositive': truePositive,
        'falsePositive': falsePositive,
        'falseNegative': falseNegative,
        'precision': precision,
        'recall': recall,
        'f1': f1,
      };
}

/// Aggregate report for one model on one dataset.
class EvalReport {
  final String modelId;
  final int totalItems;
  final int errors;
  final List<CategoryMetrics> perCategory;
  final Duration elapsed;
  final Map<String, int> confusion; // 'truth->predicted' key

  const EvalReport({
    required this.modelId,
    required this.totalItems,
    required this.errors,
    required this.perCategory,
    required this.elapsed,
    required this.confusion,
  });

  /// Macro-average F1 — unweighted mean across categories with support > 0.
  double get macroF1 {
    final scored = perCategory.where((m) => m.support > 0).toList();
    if (scored.isEmpty) return 0.0;
    final sum = scored.fold<double>(0.0, (acc, m) => acc + m.f1);
    return sum / scored.length;
  }

  /// Weighted by support — closer to "accuracy" when categories are skewed.
  double get weightedF1 {
    var totalSupport = 0;
    var weighted = 0.0;
    for (final m in perCategory) {
      totalSupport += m.support;
      weighted += m.f1 * m.support;
    }
    return totalSupport == 0 ? 0.0 : weighted / totalSupport;
  }

  Map<String, Object?> toJson() => {
        'modelId': modelId,
        'totalItems': totalItems,
        'errors': errors,
        'elapsedMs': elapsed.inMilliseconds,
        'macroF1': macroF1,
        'weightedF1': weightedF1,
        'perCategory': perCategory.map((m) => m.toJson()).toList(),
        'confusion': confusion,
      };

  /// Markdown rendering for CI logs / human review.
  String toMarkdown() {
    final buf = StringBuffer()
      ..writeln('### Eval — $modelId')
      ..writeln()
      ..writeln('- Items: $totalItems (errors: $errors)')
      ..writeln('- Elapsed: ${elapsed.inMilliseconds} ms')
      ..writeln('- Macro F1: ${macroF1.toStringAsFixed(3)}')
      ..writeln('- Weighted F1: ${weightedF1.toStringAsFixed(3)}')
      ..writeln()
      ..writeln('| Category | Support | TP | FP | FN | P | R | F1 |')
      ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|');
    for (final m in perCategory) {
      buf.writeln(
        '| ${m.category.name} | ${m.support} | ${m.truePositive} '
        '| ${m.falsePositive} | ${m.falseNegative} '
        '| ${m.precision.toStringAsFixed(3)} '
        '| ${m.recall.toStringAsFixed(3)} '
        '| ${m.f1.toStringAsFixed(3)} |',
      );
    }
    return buf.toString();
  }
}

/// Pure tally over `(truth, predicted)` pairs. Returns one [CategoryMetrics]
/// per category that has support OR has been predicted at least once, plus
/// the confusion-matrix breakdown keyed `'truth->predicted'`.
({List<CategoryMetrics> perCategory, Map<String, int> confusion})
    tallyMetrics(List<(NsfwCategory truth, NsfwCategory predicted)> pairs) {
  final tp = <NsfwCategory, int>{};
  final fp = <NsfwCategory, int>{};
  final fn = <NsfwCategory, int>{};
  final support = <NsfwCategory, int>{};
  final confusion = <String, int>{};

  for (final pair in pairs) {
    final truth = pair.$1;
    final pred = pair.$2;
    support[truth] = (support[truth] ?? 0) + 1;
    final key = '${truth.name}->${pred.name}';
    confusion[key] = (confusion[key] ?? 0) + 1;
    if (truth == pred) {
      tp[truth] = (tp[truth] ?? 0) + 1;
    } else {
      fp[pred] = (fp[pred] ?? 0) + 1;
      fn[truth] = (fn[truth] ?? 0) + 1;
    }
  }

  final seen = <NsfwCategory>{
    ...tp.keys,
    ...fp.keys,
    ...fn.keys,
    ...support.keys,
  };
  final out = seen
      .map((c) => CategoryMetrics(
            category: c,
            truePositive: tp[c] ?? 0,
            falsePositive: fp[c] ?? 0,
            falseNegative: fn[c] ?? 0,
            support: support[c] ?? 0,
          ))
      .toList()
    ..sort((a, b) => a.category.index.compareTo(b.category.index));
  return (perCategory: out, confusion: confusion);
}
