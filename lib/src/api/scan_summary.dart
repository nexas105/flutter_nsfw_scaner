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

  @override
  String toString() =>
      'ScanSummary(total=$totalScanned, nsfw=$nsfwCount, skipped=$skippedCount, failed=$failedCount)';
}
