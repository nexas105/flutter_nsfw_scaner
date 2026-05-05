import 'package:flutter/foundation.dart';

import 'body_part_detection.dart';
import 'nsfw_label.dart';
import 'scan_result.dart';

/// Classification result for a single camera frame.
///
/// Mirrors [ScanResult] but is scoped to live inference — no [ScanStatus],
/// no [fromCache], no error message. Camera errors surface via
/// [CameraScanSession] stream errors instead.
@immutable
class CameraFrameResult {
  /// When this frame was captured.
  final DateTime frameTimestamp;

  /// Classification labels sorted by NSFW priority then confidence.
  final List<NsfwLabel> labels;

  /// Detection boxes (NudeNet). Only populated in detection mode.
  final List<BodyPartDetection>? detections;

  /// Confidence threshold used for [isNsfw].
  final double confidenceThreshold;

  const CameraFrameResult({
    required this.frameTimestamp,
    required this.labels,
    this.detections,
    this.confidenceThreshold = 0.7,
  });

  /// Highest-priority category (NSFW first).
  NsfwCategory get topCategory =>
      labels.isNotEmpty ? labels.first.category : NsfwCategory.unknown;

  /// Confidence of the top category.
  double get topConfidence =>
      labels.isNotEmpty ? labels.first.confidence : 0.0;

  /// Whether this frame is classified as NSFW.
  bool get isNsfw => topCategory.isNsfw && topConfidence >= confidenceThreshold;

  /// Confidence for a specific category.
  double confidenceFor(NsfwCategory category) =>
      labels.where((l) => l.category == category).firstOrNull?.confidence ?? 0.0;

  /// Returns a copy of this frame with [detections] cleared. Used by
  /// `NsfwCameraView` (Phase 04 / WIDGET-06) on orientation change to drop
  /// stale boxes for one frame while waiting for the next analyzer result —
  /// the labels and confidence are size-agnostic and can be carried over
  /// untouched.
  CameraFrameResult copyWithoutDetections() => CameraFrameResult(
        frameTimestamp: frameTimestamp,
        labels: labels,
        detections: null,
        confidenceThreshold: confidenceThreshold,
      );

  /// Parses a camera-frame event from the native side.
  ///
  /// The wire format mirrors [ScanResult.fromMap] minus asset fields:
  /// `{frameTimestamp, labels, detections, scannedAt}`.
  factory CameraFrameResult.fromMap(
    Map<dynamic, dynamic> map, {
    double confidenceThreshold = 0.7,
  }) {
    final rawLabels = (map['labels'] as List<dynamic>?) ?? [];
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

    final ts = map['frameTimestamp'];
    final frameTimestamp = ts is int
        ? DateTime.fromMillisecondsSinceEpoch(ts)
        : DateTime.now();

    return CameraFrameResult(
      frameTimestamp: frameTimestamp,
      labels: labels,
      detections: detections,
      confidenceThreshold: confidenceThreshold,
    );
  }

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
}
