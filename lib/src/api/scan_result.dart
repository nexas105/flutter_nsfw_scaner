import 'package:flutter/foundation.dart';
import '../l10n/nsfw_localizations.dart';
import 'body_part_detection.dart';
import 'media_item.dart';
import 'nsfw_label.dart';
import 'scan_decision.dart';

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

  /// Optional per-category overrides for [confidenceThreshold]. When non-null,
  /// [isNsfw] (and the category-specific shortcuts [hasNudity],
  /// [hasExplicitContent], [isSuggestive]) walk every NSFW-priority label and
  /// compare its confidence against the threshold for that label's category,
  /// falling back to the scalar [confidenceThreshold] for unmapped categories.
  ///
  /// Lets product code express "block explicit aggressively (0.5) but tolerate
  /// suggestive (0.95)" without re-classifying.
  final Map<NsfwCategory, double>? thresholdsByCategory;

  /// Moderator override pulled from the active [DecisionStore], if any.
  /// `ScanDecision.allow` overrides [isNsfw] to `false`; `ScanDecision.block`
  /// overrides it to `true`. `null` (or `ScanDecision.reset`) defers to the
  /// raw classifier output.
  final ScanDecision? userDecision;

  const ScanResult({
    required this.item,
    required this.status,
    required this.labels,
    required this.scannedAt,
    required this.confidenceThreshold,
    this.errorMessage,
    this.fromCache = false,
    this.detections,
    this.thresholdsByCategory,
    this.userDecision,
  });

  /// Highest-priority category reported for this item.
  NsfwCategory get topCategory =>
      labels.isNotEmpty ? labels.first.category : NsfwCategory.unknown;

  /// Confidence score for [topCategory].
  double get topConfidence => labels.isNotEmpty ? labels.first.confidence : 0.0;

  /// Threshold applied to a label of [category]. Honours
  /// [thresholdsByCategory] when set; otherwise the scalar
  /// [confidenceThreshold].
  double thresholdFor(NsfwCategory category) =>
      thresholdsByCategory?[category] ?? confidenceThreshold;

  /// Whether this item crosses its applicable threshold for an NSFW category.
  ///
  /// When [thresholdsByCategory] is set, walks every NSFW-priority label and
  /// returns true as soon as one crosses its per-category threshold — so an
  /// explicit-at-0.6 label can flag the result even when the top label is a
  /// suggestive-at-0.9 sitting under its own 0.95 threshold.
  ///
  /// [userDecision] wins when set to `ScanDecision.allow` or
  /// `ScanDecision.block`, so moderator overrides survive future re-scans.
  bool get isNsfw {
    if (userDecision == ScanDecision.allow) return false;
    if (userDecision == ScanDecision.block) return true;
    if (status != ScanStatus.completed) return false;
    if (thresholdsByCategory == null) {
      return topCategory.isNsfw && topConfidence >= confidenceThreshold;
    }
    for (final label in labels) {
      if (!label.category.isNsfw) continue;
      if (label.confidence >= thresholdFor(label.category)) return true;
    }
    return false;
  }

  /// Whether the item completed classification and did not cross the NSFW
  /// threshold.
  bool get isSafe => status == ScanStatus.completed && !isNsfw;

  /// Returns the confidence for [category], or zero when the category is not
  /// present in [labels].
  double confidenceFor(NsfwCategory category) =>
      labels.where((l) => l.category == category).firstOrNull?.confidence ??
      0.0;

  /// Returns true when the highest-confidence label of [category] crosses its
  /// per-category threshold (or scalar fallback). Used by category-specific
  /// shortcuts so per-category thresholds work uniformly.
  bool _categoryCrossed(NsfwCategory category) {
    if (status != ScanStatus.completed) return false;
    if (thresholdsByCategory == null) {
      // Legacy behaviour: only the top label was considered. Preserved so
      // existing callers see the same answer when no per-category map is set.
      return topCategory == category &&
          topConfidence >= confidenceThreshold;
    }
    final conf = confidenceFor(category);
    return conf > 0 && conf >= thresholdFor(category);
  }

  /// True when at least one [NsfwCategory.nudity] label crosses its threshold.
  bool get hasNudity => _categoryCrossed(NsfwCategory.nudity);

  /// True when at least one [NsfwCategory.explicitNudity] label crosses its
  /// threshold. Stricter signal than [isNsfw].
  bool get hasExplicitContent =>
      _categoryCrossed(NsfwCategory.explicitNudity);

  /// True when at least one [NsfwCategory.suggestive] label crosses its
  /// threshold. Treated as a separate signal from [isNsfw] because some
  /// products allow suggestive content but block nudity.
  bool get isSuggestive => _categoryCrossed(NsfwCategory.suggestive);

  /// True when at least one body-part detection box is present. Only
  /// populated for [ScanMode.detection] runs.
  bool get hasDetections => detections != null && detections!.isNotEmpty;

  /// English bucket string for [topConfidence] — kept for source-level
  /// compatibility with v2.4.x and earlier. Prefer
  /// [localizedConfidenceDescription] for user-facing strings.
  String get confidenceDescription =>
      localizedConfidenceDescription(const NsfwLocalizationsEn());

  /// Localized bucket string for [topConfidence]. Defaults to
  /// [NsfwLocalizations.current]; pass an explicit [locale] to override.
  String localizedConfidenceDescription([NsfwLocalizations? locale]) {
    final l = locale ?? NsfwLocalizations.current;
    if (topConfidence >= 0.9) return l.confidenceVeryHigh;
    if (topConfidence >= 0.75) return l.confidenceHigh;
    if (topConfidence >= 0.6) return l.confidenceModerate;
    if (topConfidence >= 0.4) return l.confidenceLow;
    return l.confidenceVeryLow;
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
    Map<NsfwCategory, double>? thresholdsByCategory,
    List<NsfwLabel>? labels,
  }) =>
      ScanResult(
        item: MediaItem(localIdentifier: localIdentifier, type: type),
        status: status,
        labels: labels ??
            [NsfwLabel(category: category, confidence: confidence)],
        scannedAt: scannedAt ?? DateTime.now(),
        confidenceThreshold: confidenceThreshold,
        fromCache: fromCache,
        detections: detections,
        thresholdsByCategory: thresholdsByCategory,
      );

  /// Returns a copy with a new set of per-category thresholds (or none).
  /// Lets callers evaluate the same raw model output under different policies
  /// without re-running inference. `null` clears the override and reverts to
  /// scalar [confidenceThreshold] semantics.
  ScanResult withThresholds(Map<NsfwCategory, double>? thresholdsByCategory) =>
      ScanResult(
        item: item,
        status: status,
        labels: labels,
        scannedAt: scannedAt,
        confidenceThreshold: confidenceThreshold,
        errorMessage: errorMessage,
        fromCache: fromCache,
        detections: detections,
        thresholdsByCategory: thresholdsByCategory,
        userDecision: userDecision,
      );

  /// Returns a copy with a moderator override attached. Pass `null` (or
  /// `ScanDecision.reset`) to clear an existing decision.
  ScanResult withUserDecision(ScanDecision? decision) => ScanResult(
        item: item,
        status: status,
        labels: labels,
        scannedAt: scannedAt,
        confidenceThreshold: confidenceThreshold,
        errorMessage: errorMessage,
        fromCache: fromCache,
        detections: detections,
        thresholdsByCategory: thresholdsByCategory,
        userDecision:
            decision == ScanDecision.reset ? null : decision,
      );

  /// Parses a method-channel result emitted by the native scanner.
  factory ScanResult.fromMap(
    Map<dynamic, dynamic> map, {
    double confidenceThreshold = 0.7,
    Map<NsfwCategory, double>? thresholdsByCategory,
    ScanDecision? userDecision,
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
      thresholdsByCategory: thresholdsByCategory ??
          _thresholdsFromMap(map['thresholdsByCategory']),
      userDecision: userDecision ??
          ScanDecision.fromWire(map['userDecision'] as String?),
    );
  }

  /// Parses `{categoryName: threshold}` shaped maps from method-channel or
  /// JSON payloads. Unknown categories are skipped; out-of-range values are
  /// clamped into `[0.0, 1.0]`. Returns null when the input does not yield
  /// at least one valid entry.
  static Map<NsfwCategory, double>? _thresholdsFromMap(Object? raw) {
    if (raw is! Map) return null;
    final out = <NsfwCategory, double>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! num) continue;
      final category = NsfwCategory.values.firstWhere(
        (c) => c.name == key,
        orElse: () => NsfwCategory.unknown,
      );
      if (category == NsfwCategory.unknown && key != 'unknown') continue;
      out[category] = value.toDouble().clamp(0.0, 1.0);
    }
    return out.isEmpty ? null : out;
  }

  static Map<String, double>? _thresholdsToMap(
    Map<NsfwCategory, double>? thresholds,
  ) {
    if (thresholds == null || thresholds.isEmpty) return null;
    return {for (final e in thresholds.entries) e.key.name: e.value};
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
        if (_thresholdsToMap(thresholdsByCategory) != null)
          'thresholdsByCategory': _thresholdsToMap(thresholdsByCategory),
        if (userDecision != null) 'userDecision': userDecision!.wireValue,
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
        thresholdsByCategory:
            _thresholdsFromMap(json['thresholdsByCategory']),
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
