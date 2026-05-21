import 'package:nsfw_detect/nsfw_detect.dart';

import 'eval_dataset.dart';
import 'eval_runner.dart';

/// Per-subcategory false-positive tally for a "safe set" — items whose
/// ground-truth category is `safe` but that the classifier flagged as NSFW.
/// Used by the FP-regression suite to surface the specific edge cases
/// (`beach_photo`, `art_nude`, `baby_bath`, `anime`, …) that have burned
/// us in the past.
class SubcategoryFpRate {
  final String subcategory;
  final int total;
  final int falsePositives;
  final List<String> exampleFalsePositivePaths;

  const SubcategoryFpRate({
    required this.subcategory,
    required this.total,
    required this.falsePositives,
    required this.exampleFalsePositivePaths,
  });

  double get rate => total == 0 ? 0.0 : falsePositives / total;

  Map<String, Object?> toJson() => {
        'subcategory': subcategory,
        'total': total,
        'falsePositives': falsePositives,
        'rate': rate,
        if (exampleFalsePositivePaths.isNotEmpty)
          'examples': exampleFalsePositivePaths,
      };
}

/// FP-regression report: a list of [SubcategoryFpRate] entries plus the
/// overall rate, optionally compared to a baseline.
class FpRegressionReport {
  final String modelId;
  final List<SubcategoryFpRate> perSubcategory;
  final int totalSafeItems;
  final int totalFalsePositives;

  /// Optional `Map<subcategory, baselineRate>` supplied by the caller; used
  /// by [exceeded] to highlight degraded buckets.
  final Map<String, double>? baseline;

  /// Tolerance — a current rate above `baseline[sub] + tolerance` counts as
  /// a regression. Default 5 percentage points.
  final double tolerance;

  const FpRegressionReport({
    required this.modelId,
    required this.perSubcategory,
    required this.totalSafeItems,
    required this.totalFalsePositives,
    this.baseline,
    this.tolerance = 0.05,
  });

  double get overallRate =>
      totalSafeItems == 0 ? 0.0 : totalFalsePositives / totalSafeItems;

  /// Returns subcategories whose current rate is more than [tolerance]
  /// above the baseline. Empty when no baseline is supplied or every
  /// bucket stays within tolerance.
  List<SubcategoryFpRate> get exceeded {
    final b = baseline;
    if (b == null) return const [];
    return perSubcategory.where((s) {
      final base = b[s.subcategory];
      if (base == null) return false;
      return s.rate > base + tolerance;
    }).toList();
  }

  Map<String, Object?> toJson() => {
        'modelId': modelId,
        'totalSafeItems': totalSafeItems,
        'totalFalsePositives': totalFalsePositives,
        'overallRate': overallRate,
        'perSubcategory':
            perSubcategory.map((s) => s.toJson()).toList(),
        'tolerance': tolerance,
        if (baseline != null) 'baseline': baseline,
      };

  String toMarkdown() {
    final buf = StringBuffer()
      ..writeln('### FP regression — $modelId')
      ..writeln()
      ..writeln(
        '- Overall: $totalFalsePositives / $totalSafeItems '
        '= ${(overallRate * 100).toStringAsFixed(2)}%',
      )
      ..writeln()
      ..writeln('| Subcategory | Total | FP | Rate | Baseline | Δ |')
      ..writeln('|---|---:|---:|---:|---:|---:|');
    for (final s in perSubcategory) {
      final base = baseline?[s.subcategory];
      final delta = base == null ? null : s.rate - base;
      final exceededMark = delta != null && delta > tolerance ? ' ⚠️' : '';
      buf.writeln(
        '| ${s.subcategory} | ${s.total} | ${s.falsePositives} '
        '| ${(s.rate * 100).toStringAsFixed(2)}% '
        '| ${base == null ? '—' : '${(base * 100).toStringAsFixed(2)}%'} '
        '| ${delta == null ? '—' : '${(delta * 100).toStringAsFixed(2)}pp$exceededMark'} |',
      );
    }
    return buf.toString();
  }
}

/// Walks [dataset] (which MUST consist of `truth == safe` items, each with
/// a `subcategory` tag), runs [scan] over them, and tallies how often the
/// classifier flagged them as NSFW per subcategory.
///
/// `unknown` predictions are treated as non-NSFW so a flaky classifier
/// doesn't artificially inflate FP rate.
Future<FpRegressionReport> runFpRegression({
  required EvalDataset dataset,
  required String modelId,
  required ScanByPath scan,
  Map<String, double>? baseline,
  double tolerance = 0.05,
  NsfwCategory Function(ScanResult)? predictionMapper,
  int examplesPerBucket = 3,
  void Function(int done, int total)? progress,
}) async {
  final mapper = predictionMapper ?? defaultPredictionMapper;
  final perBucketTotal = <String, int>{};
  final perBucketFp = <String, int>{};
  final perBucketExamples = <String, List<String>>{};
  var totalSafe = 0;
  var totalFp = 0;

  for (var i = 0; i < dataset.items.length; i++) {
    final item = dataset.items[i];
    progress?.call(i + 1, dataset.items.length);
    if (item.truth != NsfwCategory.safe) continue;
    final bucket = item.subcategory ?? 'untagged';
    totalSafe++;
    perBucketTotal[bucket] = (perBucketTotal[bucket] ?? 0) + 1;
    NsfwCategory predicted;
    try {
      final result = await scan(item.resolvedPath);
      predicted = mapper(result);
    } catch (_) {
      predicted = NsfwCategory.unknown;
    }
    if (predicted.isNsfw) {
      totalFp++;
      perBucketFp[bucket] = (perBucketFp[bucket] ?? 0) + 1;
      final examples = perBucketExamples.putIfAbsent(bucket, () => []);
      if (examples.length < examplesPerBucket) {
        examples.add(item.resolvedPath);
      }
    }
  }

  final per = perBucketTotal.entries
      .map((e) => SubcategoryFpRate(
            subcategory: e.key,
            total: e.value,
            falsePositives: perBucketFp[e.key] ?? 0,
            exampleFalsePositivePaths:
                perBucketExamples[e.key] ?? const <String>[],
          ))
      .toList()
    ..sort((a, b) => b.rate.compareTo(a.rate));

  return FpRegressionReport(
    modelId: modelId,
    perSubcategory: per,
    totalSafeItems: totalSafe,
    totalFalsePositives: totalFp,
    baseline: baseline,
    tolerance: tolerance,
  );
}
