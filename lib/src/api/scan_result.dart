import 'package:flutter/foundation.dart';
import 'body_part_detection.dart';
import 'media_item.dart';
import 'nsfw_label.dart';

/// Terminal status for scanning a single media item.
enum ScanStatus {
  /// The item was classified and may contain labels or detections.
  completed,

  /// The native scanner could not classify the item.
  failed,

  /// The item was intentionally skipped, often because of configuration,
  /// permissions, or cached state.
  skipped;

  static ScanStatus fromString(String s) => switch (s) {
        'completed' => ScanStatus.completed,
        'failed' => ScanStatus.failed,
        'skipped' => ScanStatus.skipped,
        _ => ScanStatus.completed,
      };
}

/// Classification or detection result for one photo-library asset, file, or
/// byte-buffer scan.
///
/// [labels] contain probabilistic model confidences sorted so NSFW categories
/// take priority over safe categories when scores tie. [isNsfw] is a
/// convenience interpretation based on [topCategory], [topConfidence], and
/// [confidenceThreshold]; callers should still review raw labels and tune
/// thresholds for their use case.
///
/// A result may come from the on-device cache when [fromCache] is true. The
/// plugin does not imply that cached or fresh labels are perfectly accurate.
@immutable
class ScanResult {
  /// Media item that produced this result.
  final MediaItem item;

  /// Whether classification completed, failed, or was skipped.
  final ScanStatus status;

  /// Model labels sorted by NSFW priority and confidence.
  final List<NsfwLabel> labels;

  /// Platform error message when [status] is [ScanStatus.failed].
  final String? errorMessage;

  /// Time the result was emitted or reconstructed.
  final DateTime scannedAt;

  /// Threshold used by [isNsfw].
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

  /// Highest-priority category reported for this item.
  NsfwCategory get topCategory =>
      labels.isNotEmpty ? labels.first.category : NsfwCategory.unknown;

  /// Confidence score for [topCategory].
  double get topConfidence => labels.isNotEmpty ? labels.first.confidence : 0.0;

  /// Whether this item crosses [confidenceThreshold] for an NSFW category.
  bool get isNsfw =>
      status == ScanStatus.completed &&
      topCategory.isNsfw &&
      topConfidence >= confidenceThreshold;

  /// Whether the item completed classification and did not cross the NSFW
  /// threshold.
  bool get isSafe => status == ScanStatus.completed && !isNsfw;

  /// Returns the confidence for [category], or zero when the category is not
  /// present in [labels].
  double confidenceFor(NsfwCategory category) =>
      labels.where((l) => l.category == category).firstOrNull?.confidence ??
      0.0;

  /// True when the top category is [NsfwCategory.nudity] above threshold.
  bool get hasNudity =>
      status == ScanStatus.completed &&
      topCategory == NsfwCategory.nudity &&
      topConfidence >= confidenceThreshold;

  /// True when the top category is [NsfwCategory.explicitNudity] above
  /// threshold. Stricter signal than [isNsfw].
  bool get hasExplicitContent =>
      status == ScanStatus.completed &&
      topCategory == NsfwCategory.explicitNudity &&
      topConfidence >= confidenceThreshold;

  /// True when the top category is [NsfwCategory.suggestive] above threshold.
  /// Treated as a separate signal from [isNsfw] because some products allow
  /// suggestive content but block nudity.
  bool get isSuggestive =>
      status == ScanStatus.completed &&
      topCategory == NsfwCategory.suggestive &&
      topConfidence >= confidenceThreshold;

  /// True when at least one body-part detection box is present. Only
  /// populated for [ScanMode.detection] runs.
  bool get hasDetections => detections != null && detections!.isNotEmpty;

  /// Human-readable bucket for [topConfidence] — for logs, debug UIs, or
  /// user-facing strings ("Very high" / "High" / "Moderate" / "Low" / "Very low").
  /// Not localized; wrap in your own i18n layer if needed.
  String get confidenceDescription {
    if (topConfidence >= 0.9) return 'Very high';
    if (topConfidence >= 0.75) return 'High';
    if (topConfidence >= 0.6) return 'Moderate';
    if (topConfidence >= 0.4) return 'Low';
    return 'Very low';
  }

  /// Priority order used in [ScanResult.fromMap] to break confidence ties so
  /// `topCategory` always surfaces NSFW over SFW when both are present.
  /// Lower value = higher priority. Mirrors the native-side sort in
  /// `NsfwClassification.fromDetections` (iOS) and `ScanSessionTask.kt`
  /// detection aggregation (Android).
  static int _categoryRank(NsfwCategory c) {
    switch (c) {
      case NsfwCategory.explicitNudity:
        return 0;
      case NsfwCategory.nudity:
        return 1;
      case NsfwCategory.suggestive:
        return 2;
      case NsfwCategory.safe:
        return 3;
      case NsfwCategory.unknown:
        return 4;
    }
  }

  /// Constructs a synthetic [ScanResult] with [status] = [ScanStatus.failed]
  /// for batch APIs that need to surface per-item errors without aborting the
  /// whole batch. `errorMessage` describes the underlying failure.
  factory ScanResult.failed({
    required String localIdentifier,
    required String errorMessage,
    double confidenceThreshold = 0.7,
    MediaType type = MediaType.unknown,
  }) =>
      ScanResult(
        item: MediaItem(localIdentifier: localIdentifier, type: type),
        status: ScanStatus.failed,
        labels: const [],
        scannedAt: DateTime.now(),
        confidenceThreshold: confidenceThreshold,
        errorMessage: errorMessage,
      );

  /// Test-only factory — constructs a [ScanResult] with the given category /
  /// confidence so unit tests can assert moderation logic without booting
  /// the platform channel. Not intended for production code.
  @visibleForTesting
  factory ScanResult.fake({
    String localIdentifier = 'fake-id',
    NsfwCategory category = NsfwCategory.safe,
    double confidence = 0.95,
    double confidenceThreshold = 0.7,
    ScanStatus status = ScanStatus.completed,
    MediaType type = MediaType.image,
    bool fromCache = false,
    List<BodyPartDetection>? detections,
    DateTime? scannedAt,
  }) =>
      ScanResult(
        item: MediaItem(localIdentifier: localIdentifier, type: type),
        status: status,
        labels: [NsfwLabel(category: category, confidence: confidence)],
        scannedAt: scannedAt ?? DateTime.now(),
        confidenceThreshold: confidenceThreshold,
        fromCache: fromCache,
        detections: detections,
      );

  /// Parses a method-channel result emitted by the native scanner.
  factory ScanResult.fromMap(
    Map<dynamic, dynamic> map, {
    double confidenceThreshold = 0.7,
  }) {
    final rawLabels = (map['labels'] as List<dynamic>?) ?? [];
    // Sort by NSFW priority FIRST, then confidence within each tier — a
    // detection result with both `BELLY_EXPOSED` (safe, 100%) and
    // `FEMALE_BREAST_EXPOSED` (nudity, 100%) must surface as topCategory =
    // nudity, not topCategory = safe (which is what a pure-confidence sort
    // would yield on a tie).
    final labels = rawLabels
        .map((l) => NsfwLabel.fromMap(l as Map<dynamic, dynamic>))
        .toList()
      ..sort((a, b) {
        final ra = _categoryRank(a.category);
        final rb = _categoryRank(b.category);
        if (ra != rb) return ra.compareTo(rb);
        return b.confidence.compareTo(a.confidence);
      });

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

  /// Public JSON-safe serialisation suitable for `jsonEncode` /
  /// `shared_preferences` storage. Symmetric with [ScanResult.fromJson].
  /// Includes `confidenceThreshold` so the round-trip preserves [isNsfw].
  Map<String, dynamic> toJson() => {
        ...toMap(),
        'confidenceThreshold': confidenceThreshold,
      };

  /// Restores a result previously produced by [toJson]. Missing fields fall
  /// back to the same defaults as [ScanResult.fromMap].
  factory ScanResult.fromJson(Map<String, dynamic> json) => ScanResult.fromMap(
        json,
        confidenceThreshold:
            (json['confidenceThreshold'] as num?)?.toDouble() ?? 0.7,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && item == other.item;

  @override
  int get hashCode => item.hashCode;

  @override
  String toString() =>
      'ScanResult(${item.localIdentifier}, $topCategory @ ${(topConfidence * 100).toStringAsFixed(1)}%)';
}
