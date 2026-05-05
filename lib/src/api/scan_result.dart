import 'package:flutter/foundation.dart';
import 'media_item.dart';
import 'nsfw_label.dart';

enum ScanStatus {
  completed,
  failed,
  skipped;

  static ScanStatus fromString(String s) => switch (s) {
        'completed' => ScanStatus.completed,
        'failed' => ScanStatus.failed,
        'skipped' => ScanStatus.skipped,
        _ => ScanStatus.completed,
      };
}

@immutable
class ScanResult {
  final MediaItem item;
  final ScanStatus status;
  final List<NsfwLabel> labels;
  final String? errorMessage;
  final DateTime scannedAt;
  final double confidenceThreshold;
  /// True when this result was replayed from the persistent scan cache rather
  /// than freshly classified. Subsequent scans of the same library reuse cached
  /// entries when the asset's modificationDate and modelId still match.
  final bool fromCache;

  const ScanResult({
    required this.item,
    required this.status,
    required this.labels,
    required this.scannedAt,
    required this.confidenceThreshold,
    this.errorMessage,
    this.fromCache = false,
  });

  NsfwCategory get topCategory => labels.isNotEmpty ? labels.first.category : NsfwCategory.unknown;
  double get topConfidence => labels.isNotEmpty ? labels.first.confidence : 0.0;

  bool get isNsfw =>
      status == ScanStatus.completed &&
      topCategory.isNsfw &&
      topConfidence >= confidenceThreshold;

  bool get isSafe => status == ScanStatus.completed && !isNsfw;

  double confidenceFor(NsfwCategory category) =>
      labels.where((l) => l.category == category).firstOrNull?.confidence ?? 0.0;

  factory ScanResult.fromMap(Map<dynamic, dynamic> map, {double confidenceThreshold = 0.7}) {
    final rawLabels = (map['labels'] as List<dynamic>?) ?? [];
    final labels = rawLabels
        .map((l) => NsfwLabel.fromMap(l as Map<dynamic, dynamic>))
        .toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    return ScanResult(
      item: MediaItem.fromMap(map),
      status: ScanStatus.fromString(map['status'] as String? ?? 'completed'),
      labels: labels,
      scannedAt: map['scannedAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['scannedAt'] as int)
          : DateTime.now(),
      confidenceThreshold: confidenceThreshold,
      errorMessage: map['errorMessage'] as String?,
      fromCache: map['fromCache'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && item == other.item;

  @override
  int get hashCode => item.hashCode;

  @override
  String toString() =>
      'ScanResult(${item.localIdentifier}, $topCategory @ ${(topConfidence * 100).toStringAsFixed(1)}%)';
}
