import 'package:nsfw_detect/nsfw_detect.dart';

import 'eval_dataset.dart';
import 'eval_metrics.dart';

/// Asynchronous scan dispatcher. Decoupled from `NsfwDetector` so the runner
/// can be exercised in unit tests against a fake / scripted implementation.
typedef ScanByPath = Future<ScanResult> Function(String path);

/// Maps a [ScanResult] back onto a single ground-truth-friendly category.
/// Default: result's `topCategory` if classification completed; else
/// `NsfwCategory.unknown`.
NsfwCategory defaultPredictionMapper(ScanResult result) {
  if (result.status != ScanStatus.completed) return NsfwCategory.unknown;
  return result.topCategory;
}

/// Runs the [dataset] through [scan] and tallies metrics for [modelId].
///
/// [progress] is invoked after every item with `(done, total)` — wire it to
/// a CLI progress bar or CI log line. Per-item exceptions are caught and
/// surfaced as `unknown` predictions plus an `errors` count on the report.
Future<EvalReport> runEval({
  required EvalDataset dataset,
  required String modelId,
  required ScanByPath scan,
  NsfwCategory Function(ScanResult)? predictionMapper,
  void Function(int done, int total)? progress,
}) async {
  final mapper = predictionMapper ?? defaultPredictionMapper;
  final stopwatch = Stopwatch()..start();
  final pairs = <(NsfwCategory, NsfwCategory)>[];
  var errors = 0;
  for (var i = 0; i < dataset.items.length; i++) {
    final item = dataset.items[i];
    try {
      final result = await scan(item.resolvedPath);
      pairs.add((item.truth, mapper(result)));
    } catch (_) {
      errors++;
      pairs.add((item.truth, NsfwCategory.unknown));
    }
    progress?.call(i + 1, dataset.items.length);
  }
  stopwatch.stop();
  final tally = tallyMetrics(pairs);
  return EvalReport(
    modelId: modelId,
    totalItems: dataset.items.length,
    errors: errors,
    perCategory: tally.perCategory,
    elapsed: stopwatch.elapsed,
    confusion: tally.confusion,
  );
}
