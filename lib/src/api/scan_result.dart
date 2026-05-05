import 'package:flutter/foundation.dart';
import 'body_part_detection.dart';
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

  /// Bounding-box detections from a NudeNet-style detector. Only populated
  /// when the scan ran in `ScanMode.detection` AND the detector emitted at
  /// least one box above its confidence threshold. `null` for classification
  /// runs and for detection runs that yielded no detections (BC-safe — old
  /// callers that ignore this field keep working).
  final List<BodyPartDetection>? detections;

  const ScanResult({
    required this.item,
    required this.status,
    required this.labels,
    required this.scannedAt,
    required this.confidenceThreshold,
    this.errorMessage,
    this.fromCache = false,
    this.detections,
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

    final rawDetections = map['detections'];
    List<BodyPartDetection>? detections;
    if (rawDetections is List && rawDetections.isNotEmpty) {
      detections = rawDetections
          .whereType<Map<dynamic, dynamic>>()
          .map(BodyPartDetection.fromMap)
          .toList(growable: false);
      if (detections.isEmpty) detections = null;
    }

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
      detections: detections,
    );
  }

  /// Serialises the result back to a method-channel-shaped map. Round-trip
  /// safe with [ScanResult.fromMap]. Mostly useful for tests / external
  /// caches; the plugin itself doesn't read this map back internally.
  Map<String, dynamic> toMap() => {
        ...item.toMap(),
        'status': status.name,
        'labels': labels.map((l) => l.toMap()).toList(),
        'scannedAt': scannedAt.millisecondsSinceEpoch,
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (fromCache) 'fromCache': true,
        if (detections != null)
          'detections': detections!.map((d) => d.toMap()).toList(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && item == other.item;

  @override
  int get hashCode => item.hashCode;

  @override
  String toString() =>
      'ScanResult(${item.localIdentifier}, $topCategory @ ${(topConfidence * 100).toStringAsFixed(1)}%)';
}
