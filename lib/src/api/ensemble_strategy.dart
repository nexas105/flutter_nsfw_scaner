import 'package:flutter/foundation.dart';

import 'nsfw_label.dart';
import 'scan_result.dart';

/// How [NsfwDetector] reconciles results from multiple classifier models
/// when [ScanConfiguration.ensemble] is set.
///
/// All strategies assume classifier-only models (no detectors — detector
/// outputs are spatial and not meaningfully averageable without further
/// design). The plugin documents this contract loudly: passing detector
/// model ids into an ensemble throws.
///
/// **Cost.** Each strategy runs the input through every model in the
/// ensemble, so inference time scales linearly with the model count.
/// Default: ensemble is OFF.
@immutable
sealed class EnsembleStrategy {
  EnsembleStrategy({required this.modelIds}) {
    if (modelIds.length < 2) {
      throw ArgumentError.value(
        modelIds,
        'modelIds',
        'Ensemble strategies need at least two models — use a single modelId otherwise',
      );
    }
  }

  /// Models to run, in order. Order is meaningful only for [WeightedEnsemble]'s
  /// `weights` map (which uses modelId keys) but otherwise informational.
  final List<String> modelIds;

  /// Reduce per-model results into a single [ScanResult]. The combined
  /// result carries the same `MediaItem` and `confidenceThreshold` as the
  /// inputs.
  ScanResult combine(List<ScanResult> perModelResults);
}

/// **Majority vote with confidence-band borderline rescue.**
///
/// Each model votes for its top NSFW-or-safe category. The category with
/// the most votes wins; ties resolve to the model with the highest
/// confidence among tied categories.
///
/// Models whose top confidence sits inside the borderline band
/// `[borderlineMin, borderlineMax]` (default `0.45 .. 0.55`) DO NOT vote —
/// they're treated as abstentions. This is the heart of the strategy:
/// borderline disagreements between open_nsfw_2 / AdamCodd / Falconsai
/// drop the false-positive rate noticeably vs any single model alone.
@immutable
final class MajorityEnsemble extends EnsembleStrategy {
  MajorityEnsemble({
    required super.modelIds,
    this.borderlineMin = 0.45,
    this.borderlineMax = 0.55,
  })  : assert(borderlineMin >= 0.0 && borderlineMin <= 1.0),
        assert(borderlineMax >= borderlineMin && borderlineMax <= 1.0);

  final double borderlineMin;
  final double borderlineMax;

  @override
  ScanResult combine(List<ScanResult> perModelResults) {
    if (perModelResults.isEmpty) {
      throw StateError('Cannot combine an empty perModelResults list');
    }
    final completed = perModelResults
        .where((r) => r.status == ScanStatus.completed)
        .toList(growable: false);
    if (completed.isEmpty) return perModelResults.first;

    // Confident votes only — borderline classifications abstain so they
    // can't drag the consensus the wrong direction.
    final votes = <NsfwCategory, int>{};
    final maxConfidencePerCategory = <NsfwCategory, double>{};
    for (final r in completed) {
      final c = r.topConfidence;
      if (c >= borderlineMin && c <= borderlineMax) continue;
      votes.update(r.topCategory, (n) => n + 1, ifAbsent: () => 1);
      final cur = maxConfidencePerCategory[r.topCategory] ?? 0.0;
      if (c > cur) maxConfidencePerCategory[r.topCategory] = c;
    }

    // Everyone abstained — fall back to highest-confidence raw result.
    if (votes.isEmpty) {
      completed.sort((a, b) => b.topConfidence.compareTo(a.topConfidence));
      return completed.first;
    }

    var winner = votes.entries.first.key;
    var winnerCount = votes.entries.first.value;
    for (final entry in votes.entries.skip(1)) {
      if (entry.value > winnerCount) {
        winner = entry.key;
        winnerCount = entry.value;
      } else if (entry.value == winnerCount) {
        // Tie-break by max confidence within the tied category.
        final aMax = maxConfidencePerCategory[winner] ?? 0.0;
        final bMax = maxConfidencePerCategory[entry.key] ?? 0.0;
        if (bMax > aMax) winner = entry.key;
      }
    }

    final canonical = completed.firstWhere(
      (r) => r.topCategory == winner,
      orElse: () => completed.first,
    );
    return ScanResult(
      item: canonical.item,
      status: ScanStatus.completed,
      labels: [
        NsfwLabel(category: winner, confidence: maxConfidencePerCategory[winner] ?? canonical.topConfidence),
      ],
      scannedAt: canonical.scannedAt,
      confidenceThreshold: canonical.confidenceThreshold,
    );
  }
}

/// **Weighted average of per-category confidences.**
///
/// For each category present in any model's labels, compute
/// `sum(confidence * weight) / sum(weight)`. The strategy treats missing
/// labels for a given model as `0` confidence — i.e. that model is silent
/// on that category, which still pulls the average down. The combined
/// `topCategory` is whichever category ends up highest.
///
/// `weights` keys must match the supplied [modelIds]; missing keys
/// default to `1.0`. Negative weights are rejected.
@immutable
final class WeightedEnsemble extends EnsembleStrategy {
  WeightedEnsemble({
    required super.modelIds,
    this.weights = const {},
  });

  final Map<String, double> weights;

  double _weightFor(String modelId) {
    final w = weights[modelId] ?? 1.0;
    if (w < 0) {
      throw ArgumentError.value(
        w, 'weights[$modelId]', 'ensemble weights must be non-negative');
    }
    return w;
  }

  @override
  ScanResult combine(List<ScanResult> perModelResults) {
    if (perModelResults.isEmpty) {
      throw StateError('Cannot combine an empty perModelResults list');
    }
    final completed = perModelResults
        .where((r) => r.status == ScanStatus.completed)
        .toList(growable: false);
    if (completed.isEmpty) return perModelResults.first;

    // Sum per-category weighted confidences. `modelIds` order is the source
    // of truth for which weight applies to which result — perModelResults
    // is in the same order by contract.
    final weightedSum = <NsfwCategory, double>{};
    var totalWeight = 0.0;
    for (var i = 0; i < completed.length && i < modelIds.length; i++) {
      final weight = _weightFor(modelIds[i]);
      totalWeight += weight;
      for (final label in completed[i].labels) {
        weightedSum.update(label.category,
            (s) => s + label.confidence * weight,
            ifAbsent: () => label.confidence * weight);
      }
    }
    if (totalWeight <= 0) {
      // Defensive — shouldn't happen given the non-negative check, but a
      // host app could pass `weights: {'a': 0, 'b': 0}` deliberately.
      return completed.first;
    }
    final averaged = weightedSum.entries
        .map((e) => NsfwLabel(
              category: e.key,
              confidence: e.value / totalWeight,
            ))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final canonical = completed.first;
    return ScanResult(
      item: canonical.item,
      status: ScanStatus.completed,
      labels: averaged,
      scannedAt: canonical.scannedAt,
      confidenceThreshold: canonical.confidenceThreshold,
    );
  }
}
