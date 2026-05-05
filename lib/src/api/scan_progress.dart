import 'package:flutter/foundation.dart';
import 'media_item.dart';

@immutable
class ScanProgress {
  final int scannedCount;
  final int totalCount;
  final bool isComplete;
  final MediaItem? currentItem;

  const ScanProgress({
    required this.scannedCount,
    required this.totalCount,
    required this.isComplete,
    this.currentItem,
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

  @override
  String toString() => 'ScanProgress($scannedCount/$totalCount, complete: $isComplete)';
}
