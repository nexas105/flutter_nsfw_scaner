import 'package:flutter/foundation.dart';
import 'media_item.dart';

@immutable
class ScanProgress {
  final int scannedCount;
  final int totalCount;
  final bool isComplete;
  final MediaItem? currentItem;

  /// Rolling-window throughput estimate (items/second). `null` while the
  /// session has not yet observed enough progress events to compute a
  /// stable rate (typically the first 1–2 events).
  final double? itemsPerSecond;

  /// Estimated wall-clock time remaining until the scan completes, based on
  /// [itemsPerSecond] and the remaining work. `null` when the rate is
  /// unknown or the scan is already complete.
  final Duration? estimatedRemaining;

  const ScanProgress({
    required this.scannedCount,
    required this.totalCount,
    required this.isComplete,
    this.currentItem,
    this.itemsPerSecond,
    this.estimatedRemaining,
  });

  double get fraction => totalCount > 0 ? (scannedCount / totalCount).clamp(0.0, 1.0) : 0.0;

  factory ScanProgress.fromMap(Map<dynamic, dynamic> map) => ScanProgress(
        scannedCount: map['scannedCount'] as int? ?? 0,
        totalCount: map['totalCount'] as int? ?? 0,
        isComplete: map['isComplete'] as bool? ?? false,
        currentItem: map['currentLocalId'] != null
            ? MediaItem(
                localIdentifier: map['currentLocalId'] as String,
                type: MediaType.fromString(map['currentMediaType'] as String? ?? 'image'),
              )
            : null,
      );

  ScanProgress get completed => ScanProgress(
        scannedCount: totalCount,
        totalCount: totalCount,
        isComplete: true,
        currentItem: null,
      );

  /// Returns a copy with selected fields replaced.
  ScanProgress copyWith({
    int? scannedCount,
    int? totalCount,
    bool? isComplete,
    MediaItem? currentItem,
    double? itemsPerSecond,
    Duration? estimatedRemaining,
  }) =>
      ScanProgress(
        scannedCount: scannedCount ?? this.scannedCount,
        totalCount: totalCount ?? this.totalCount,
        isComplete: isComplete ?? this.isComplete,
        currentItem: currentItem ?? this.currentItem,
        itemsPerSecond: itemsPerSecond ?? this.itemsPerSecond,
        estimatedRemaining: estimatedRemaining ?? this.estimatedRemaining,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is ScanProgress &&
        scannedCount == other.scannedCount &&
        totalCount == other.totalCount &&
        isComplete == other.isComplete &&
        currentItem == other.currentItem &&
        itemsPerSecond == other.itemsPerSecond &&
        estimatedRemaining == other.estimatedRemaining;
  }

  @override
  int get hashCode => Object.hash(
        scannedCount,
        totalCount,
        isComplete,
        currentItem,
        itemsPerSecond,
        estimatedRemaining,
      );

  @override
  String toString() => 'ScanProgress($scannedCount/$totalCount, '
      'complete: $isComplete, '
      'ips: ${itemsPerSecond?.toStringAsFixed(2)}, '
      'eta: $estimatedRemaining)';
}
