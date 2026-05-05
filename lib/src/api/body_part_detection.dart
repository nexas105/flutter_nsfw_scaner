import 'package:flutter/foundation.dart';

import 'nsfw_label.dart';

/// Axis-aligned, normalised bounding box. All values are in `[0, 1]` with
/// origin top-left, matching CoreML/Vision and TFLite SSD-style detectors
/// (after the y-flip iOS performs internally). `width` and `height` are the
/// box extents — NOT the (right, bottom) corner.
@immutable
class BoundingBox {
  /// Top-left x coordinate, normalised `[0, 1]`.
  final double x;

  /// Top-left y coordinate, normalised `[0, 1]`.
  final double y;

  /// Box width, normalised `[0, 1]`.
  final double width;

  /// Box height, normalised `[0, 1]`.
  final double height;

  const BoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Defensive parse — coerces every field through `num` and clamps to `[0, 1]`
  /// so we never paint a box outside the image.
  factory BoundingBox.fromMap(Map<dynamic, dynamic> map) {
    double parse(Object? v) {
      if (v is num) return v.toDouble().clamp(0.0, 1.0);
      return 0.0;
    }

    return BoundingBox(
      x: parse(map['x']),
      y: parse(map['y']),
      width: parse(map['width']),
      height: parse(map['height']),
    );
  }

  Map<String, dynamic> toMap() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoundingBox &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'BoundingBox(x=$x, y=$y, w=$width, h=$height)';
}

/// One body-part detection produced by an object-detection model
/// (NudeNet-style). The raw [label] is the verbatim class name from the
/// model — see [BodyPartDetection.aggregateCategoryFromLabel] for the
/// canonical [NsfwCategory] mapping the detector applied at scan time.
@immutable
class BodyPartDetection {
  /// Raw class name from the detector (e.g. `FEMALE_BREAST_EXPOSED`).
  ///
  /// External consumers building `BodyPartDetection` instances themselves
  /// can choose any label scheme; the static
  /// [aggregateCategoryFromLabel] helper only knows the standard
  /// 18-class NudeNet vocabulary.
  final String label;

  /// Detector confidence in `[0, 1]`.
  final double confidence;

  /// Normalised bounding box.
  final BoundingBox box;

  /// The canonical bucket the detector aggregated this box into. Mirrored on
  /// the wire so the UI can colour boxes consistently with the classifier
  /// pipeline without re-running the mapping. When the value is missing /
  /// unknown, the helper [aggregateCategoryFromLabel] is used as a fallback.
  final NsfwCategory aggregatedCategory;

  const BodyPartDetection({
    required this.label,
    required this.confidence,
    required this.box,
    required this.aggregatedCategory,
  });

  /// Defensive map parser. Unknown / malformed entries collapse to
  /// `aggregatedCategory = NsfwCategory.unknown` rather than throwing — the
  /// detector is the source of truth and we never want a bad map to crash a
  /// scan stream.
  factory BodyPartDetection.fromMap(Map<dynamic, dynamic> map) {
    final rawLabel = map['label'] as String? ??
        map['className'] as String? ??
        '';
    final rawConfidence = map['confidence'];
    final confidence = rawConfidence is num
        ? rawConfidence.toDouble().clamp(0.0, 1.0)
        : 0.0;

    final boxRaw = map['box'];
    final box = boxRaw is Map<dynamic, dynamic>
        ? BoundingBox.fromMap(boxRaw)
        : BoundingBox.fromMap(map); // fallback: x/y/w/h flattened

    NsfwCategory category;
    final aggRaw = map['aggregatedCategory'] ?? map['category'];
    if (aggRaw is String) {
      category = _categoryFromString(aggRaw);
    } else {
      category = aggregateCategoryFromLabel(rawLabel);
    }

    return BodyPartDetection(
      label: rawLabel,
      confidence: confidence,
      box: box,
      aggregatedCategory: category,
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'confidence': confidence,
        'box': box.toMap(),
        'aggregatedCategory': aggregatedCategory.name,
      };

  /// Canonical mapping from a NudeNet class label to [NsfwCategory]. Keep this
  /// pure / side-effect free so external consumers can replace it without
  /// touching the plugin internals.
  ///
  /// The 18 NudeNet classes are bucketed as:
  ///   - genitalia / anus *_EXPOSED → [NsfwCategory.explicitNudity]
  ///   - breast / buttocks *_EXPOSED → [NsfwCategory.nudity]
  ///   - genitalia / breast / buttocks *_COVERED → [NsfwCategory.suggestive]
  ///   - face / feet / belly / armpits → [NsfwCategory.safe]
  ///   - anything else → [NsfwCategory.unknown]
  static NsfwCategory aggregateCategoryFromLabel(String rawLabel) {
    final normalized = rawLabel.trim().toUpperCase();
    switch (normalized) {
      // ── Explicit (exposed genitalia / anus) ──────────────────────────────
      case 'FEMALE_GENITALIA_EXPOSED':
      case 'MALE_GENITALIA_EXPOSED':
      case 'ANUS_EXPOSED':
        return NsfwCategory.explicitNudity;

      // ── Nudity (exposed breast / buttocks) ───────────────────────────────
      case 'FEMALE_BREAST_EXPOSED':
      case 'MALE_BREAST_EXPOSED':
      case 'BUTTOCKS_EXPOSED':
        return NsfwCategory.nudity;

      // ── Suggestive (covered intimate parts) ──────────────────────────────
      case 'FEMALE_GENITALIA_COVERED':
      case 'FEMALE_BREAST_COVERED':
      case 'BUTTOCKS_COVERED':
      case 'ANUS_COVERED':
        return NsfwCategory.suggestive;

      // ── Safe (non-intimate body parts) ───────────────────────────────────
      case 'FACE_FEMALE':
      case 'FACE_MALE':
      case 'FEET_EXPOSED':
      case 'FEET_COVERED':
      case 'BELLY_EXPOSED':
      case 'BELLY_COVERED':
      case 'ARMPITS_EXPOSED':
      case 'ARMPITS_COVERED':
        return NsfwCategory.safe;

      default:
        return NsfwCategory.unknown;
    }
  }

  static NsfwCategory _categoryFromString(String s) {
    switch (s) {
      case 'safe':
        return NsfwCategory.safe;
      case 'suggestive':
        return NsfwCategory.suggestive;
      case 'nudity':
        return NsfwCategory.nudity;
      case 'explicitNudity':
        return NsfwCategory.explicitNudity;
      default:
        return NsfwCategory.unknown;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BodyPartDetection &&
          label == other.label &&
          confidence == other.confidence &&
          box == other.box &&
          aggregatedCategory == other.aggregatedCategory;

  @override
  int get hashCode =>
      Object.hash(label, confidence, box, aggregatedCategory);

  @override
  String toString() =>
      'BodyPartDetection($label @ ${(confidence * 100).toStringAsFixed(1)}%, $box, $aggregatedCategory)';
}
