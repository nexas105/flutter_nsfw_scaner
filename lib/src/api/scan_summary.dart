import 'package:flutter/foundation.dart';

@immutable
class ScanSummary {
  final int totalScanned;
  final int nsfwCount;
  final int skippedCount;
  final int failedCount;
  final Duration elapsed;
  final bool wasCancelled;

  const ScanSummary({
    required this.totalScanned,
    required this.nsfwCount,
    required this.skippedCount,
    required this.failedCount,
    required this.elapsed,
    required this.wasCancelled,
  });

  int get safeCount => totalScanned - nsfwCount - skippedCount - failedCount;
  double get nsfwFraction => totalScanned > 0 ? nsfwCount / totalScanned : 0.0;

  const ScanSummary.empty()
      : totalScanned = 0,
        nsfwCount = 0,
        skippedCount = 0,
        failedCount = 0,
        elapsed = Duration.zero,
        wasCancelled = false;

  /// Returns a copy of this [ScanSummary] with selected fields replaced.
  ScanSummary copyWith({
    int? totalScanned,
    int? nsfwCount,
    int? skippedCount,
    int? failedCount,
    Duration? elapsed,
    bool? wasCancelled,
  }) =>
      ScanSummary(
        totalScanned: totalScanned ?? this.totalScanned,
        nsfwCount: nsfwCount ?? this.nsfwCount,
        skippedCount: skippedCount ?? this.skippedCount,
        failedCount: failedCount ?? this.failedCount,
        elapsed: elapsed ?? this.elapsed,
        wasCancelled: wasCancelled ?? this.wasCancelled,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is ScanSummary &&
        totalScanned == other.totalScanned &&
        nsfwCount == other.nsfwCount &&
        skippedCount == other.skippedCount &&
        failedCount == other.failedCount &&
        elapsed == other.elapsed &&
        wasCancelled == other.wasCancelled;
  }

  @override
  int get hashCode => Object.hash(
        totalScanned,
        nsfwCount,
        skippedCount,
        failedCount,
        elapsed,
        wasCancelled,
      );

  @override
  String toString() =>
      'ScanSummary(totalScanned: $totalScanned, nsfwCount: $nsfwCount, '
      'skippedCount: $skippedCount, failedCount: $failedCount, '
      'elapsed: $elapsed, wasCancelled: $wasCancelled)';
}
