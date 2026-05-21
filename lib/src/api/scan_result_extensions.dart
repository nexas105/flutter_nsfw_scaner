import 'nsfw_label.dart';
import 'scan_result.dart';

/// Convenience aggregations and diffs over `List<ScanResult>`.
///
/// Useful when comparing two scans of the same library — e.g. "what's new
/// since yesterday?" — without writing the boilerplate map / set logic each
/// time.
extension ScanResultListConvenience on List<ScanResult> {
  /// Items in `this` whose `isNsfw` flag changed relative to [previous],
  /// or which are not present in [previous] at all.
  ///
  /// Identity is keyed by `item.localIdentifier`.
  List<ScanResult> changedFrom(List<ScanResult> previous) {
    final prev = {for (final r in previous) r.item.localIdentifier: r};
    return where((r) {
      final p = prev[r.item.localIdentifier];
      return p == null || p.isNsfw != r.isNsfw;
    }).toList(growable: false);
  }

  /// Items in `this` whose `localIdentifier` does not appear in [previous].
  List<ScanResult> newSince(List<ScanResult> previous) {
    final prevIds = {for (final r in previous) r.item.localIdentifier};
    return where((r) => !prevIds.contains(r.item.localIdentifier))
        .toList(growable: false);
  }

  /// Items in this list that are NSFW per their own `confidenceThreshold`.
  List<ScanResult> get nsfwOnly =>
      where((r) => r.isNsfw).toList(growable: false);

  /// Items that completed successfully (status == completed).
  List<ScanResult> get completedOnly => where(
        (r) => r.status == ScanStatus.completed,
      ).toList(growable: false);

  /// Items that failed (status == failed).
  List<ScanResult> get failedOnly => where(
        (r) => r.status == ScanStatus.failed,
      ).toList(growable: false);

  /// Count of items per top category.
  Map<NsfwCategory, int> get countByCategory {
    final counts = <NsfwCategory, int>{};
    for (final r in this) {
      counts[r.topCategory] = (counts[r.topCategory] ?? 0) + 1;
    }
    return counts;
  }
}
