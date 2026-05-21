import 'package:flutter/foundation.dart';

import 'nsfw_label.dart';

/// Discriminator for [TelemetryEvent]. New variants may be added in a minor
/// release; callers should treat unknown enum entries as ignorable rather
/// than throwing.
enum TelemetryEventType {
  /// A library / picker scan was started via `NsfwDetector.startScan` or
  /// `pickAndScan`. Carries the configured `modelId`.
  scanStarted,

  /// One per-asset result was emitted from a session. Carries `modelId`,
  /// `topCategory`, `confidenceBucket`, `fromCache`. Includes `localId` only
  /// when telemetry is opted in via `NsfwDetector.includeLocalIdsInTelemetry`.
  scanCompleted,

  /// A library / picker scan finished. Carries `elapsed` and `extras`
  /// (`totalScanned`, `nsfwCount`, `skippedCount`, `failedCount`,
  /// `wasCancelled`).
  scanFinished,

  /// A one-shot headless scan (`scanBytes` / `scanFile` / `scanAsset` /
  /// `scanUrl` / `scanImageProvider`) finished. Carries `modelId`,
  /// `topCategory`, `confidenceBucket`, `elapsed`, and `extras['source']`
  /// (one of `bytes`, `file`, `asset`, `url`, `imageProvider`).
  classifyTime,

  /// `NsfwDetector.preloadModel` completed (success or failure). Carries
  /// `modelId`, `elapsed`, and `extras['ok']` (bool).
  modelLoaded,

  /// `NsfwDetector.downloadModel` was kicked off. Carries `modelId`.
  downloadStarted,

  /// A native download progress event was delivered. Carries `modelId`,
  /// `downloadedBytes`, `totalBytes`, `downloadFraction` (0..1).
  downloadProgress,

  /// `NsfwDetector.downloadModel` returned. Carries `modelId`, `elapsed`,
  /// and `extras['ok']` (bool).
  downloadFinished,

  /// `NsfwDetector.cancelScan` was acted on by the native side.
  cancelHonored,

  /// `NsfwDetector.scheduleBackgroundSweep` / `cancelBackgroundSweep`
  /// transitioned the dispatcher state. Carries
  /// `extras['kind']` (`scheduled` / `cancelled`).
  backgroundSweepChanged,
}

/// Buckets a `[0.0, 1.0]` confidence into a decile (0..9). Returns `null`
/// for negative or non-finite inputs so callers can carry through "no score".
int? confidenceBucketOf(double? confidence) {
  if (confidence == null || !confidence.isFinite || confidence < 0) return null;
  final clamped = confidence.clamp(0.0, 1.0);
  if (clamped >= 1.0) return 9;
  return (clamped * 10).floor();
}

/// Structured event emitted to `NsfwDetector.onTelemetryEvent`.
///
/// Each field is nullable so future event variants can extend the surface
/// without adding new types — callers should always check `type` and read
/// only the fields documented for that variant.
///
/// PII guarantee: `localId` is always `null` unless the host opts in via
/// `NsfwDetector.includeLocalIdsInTelemetry = true`. All other fields are
/// model / timing / aggregated metadata.
@immutable
class TelemetryEvent {
  /// Discriminator for which factory produced this event.
  final TelemetryEventType type;

  /// Wall-clock time the event was emitted.
  final DateTime at;

  /// Model identifier the event concerns (e.g. `opennsfw2_coreml`).
  final String? modelId;

  /// Wall-clock duration covered by this event (download time, scan time,
  /// session elapsed). `null` for instantaneous transitions.
  final Duration? elapsed;

  /// Top label's confidence binned into a 0..9 decile, suppressing the raw
  /// value so logs can roll up without leaking exact scores.
  final int? confidenceBucket;

  /// Top label's NSFW category for scan-style events.
  final NsfwCategory? topCategory;

  /// `true` when the result was served by the on-device cache.
  final bool? fromCache;

  /// Download progress fraction in `[0.0, 1.0]` for `downloadProgress` events.
  final double? downloadFraction;

  /// Bytes already downloaded for `downloadProgress` events.
  final int? downloadedBytes;

  /// Total bytes the download is expected to deliver (when known).
  final int? totalBytes;

  /// Asset's `localIdentifier`. Always `null` unless
  /// `NsfwDetector.includeLocalIdsInTelemetry` is `true`.
  final String? localId;

  /// Failure message when the event is reporting an error condition.
  final String? errorMessage;

  /// Open-ended bag for event-specific data. Read-only at the API surface —
  /// treat the contents as documented per-variant in [TelemetryEventType].
  final Map<String, Object?> extras;

  const TelemetryEvent({
    required this.type,
    required this.at,
    this.modelId,
    this.elapsed,
    this.confidenceBucket,
    this.topCategory,
    this.fromCache,
    this.downloadFraction,
    this.downloadedBytes,
    this.totalBytes,
    this.localId,
    this.errorMessage,
    this.extras = const {},
  });

  /// Convenience: scan-started event.
  factory TelemetryEvent.scanStarted({
    required String modelId,
    DateTime? at,
    Map<String, Object?>? extras,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.scanStarted,
        at: at ?? DateTime.now(),
        modelId: modelId,
        extras: extras ?? const {},
      );

  /// Convenience: per-asset scan completed inside a session.
  factory TelemetryEvent.scanCompleted({
    required String modelId,
    required NsfwCategory topCategory,
    required double topConfidence,
    required bool fromCache,
    String? localId,
    DateTime? at,
    Map<String, Object?>? extras,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.scanCompleted,
        at: at ?? DateTime.now(),
        modelId: modelId,
        topCategory: topCategory,
        confidenceBucket: confidenceBucketOf(topConfidence),
        fromCache: fromCache,
        localId: localId,
        extras: extras ?? const {},
      );

  /// Convenience: session finished.
  factory TelemetryEvent.scanFinished({
    required String modelId,
    required Duration elapsed,
    required int totalScanned,
    required int nsfwCount,
    required int skippedCount,
    required int failedCount,
    required bool wasCancelled,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.scanFinished,
        at: at ?? DateTime.now(),
        modelId: modelId,
        elapsed: elapsed,
        extras: {
          'totalScanned': totalScanned,
          'nsfwCount': nsfwCount,
          'skippedCount': skippedCount,
          'failedCount': failedCount,
          'wasCancelled': wasCancelled,
        },
      );

  /// Convenience: one-shot headless scan completed.
  factory TelemetryEvent.classifyTime({
    required String modelId,
    required String source,
    required NsfwCategory topCategory,
    required double topConfidence,
    required Duration elapsed,
    bool fromCache = false,
    String? localId,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.classifyTime,
        at: at ?? DateTime.now(),
        modelId: modelId,
        elapsed: elapsed,
        topCategory: topCategory,
        confidenceBucket: confidenceBucketOf(topConfidence),
        fromCache: fromCache,
        localId: localId,
        extras: {'source': source},
      );

  factory TelemetryEvent.modelLoaded({
    required String modelId,
    required Duration elapsed,
    required bool ok,
    String? errorMessage,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.modelLoaded,
        at: at ?? DateTime.now(),
        modelId: modelId,
        elapsed: elapsed,
        errorMessage: errorMessage,
        extras: {'ok': ok},
      );

  factory TelemetryEvent.downloadStarted({
    required String modelId,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.downloadStarted,
        at: at ?? DateTime.now(),
        modelId: modelId,
      );

  factory TelemetryEvent.downloadProgress({
    required String modelId,
    required int downloadedBytes,
    int? totalBytes,
    DateTime? at,
  }) {
    double? fraction;
    if (totalBytes != null && totalBytes > 0) {
      fraction = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return TelemetryEvent(
      type: TelemetryEventType.downloadProgress,
      at: at ?? DateTime.now(),
      modelId: modelId,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      downloadFraction: fraction,
    );
  }

  factory TelemetryEvent.downloadFinished({
    required String modelId,
    required Duration elapsed,
    required bool ok,
    String? errorMessage,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.downloadFinished,
        at: at ?? DateTime.now(),
        modelId: modelId,
        elapsed: elapsed,
        errorMessage: errorMessage,
        extras: {'ok': ok},
      );

  factory TelemetryEvent.cancelHonored({String? modelId, DateTime? at}) =>
      TelemetryEvent(
        type: TelemetryEventType.cancelHonored,
        at: at ?? DateTime.now(),
        modelId: modelId,
      );

  factory TelemetryEvent.backgroundSweepChanged({
    required String kind,
    DateTime? at,
  }) =>
      TelemetryEvent(
        type: TelemetryEventType.backgroundSweepChanged,
        at: at ?? DateTime.now(),
        extras: {'kind': kind},
      );

  @override
  String toString() => 'TelemetryEvent(${type.name}'
      '${modelId != null ? ', model=$modelId' : ''}'
      '${elapsed != null ? ', elapsed=${elapsed!.inMilliseconds}ms' : ''}'
      '${topCategory != null ? ', top=${topCategory!.name}' : ''}'
      '${confidenceBucket != null ? ', bucket=$confidenceBucket' : ''}'
      ')';
}

/// Signature for the telemetry sink installed on
/// `NsfwDetector.onTelemetryEvent`. Handlers MUST be fast and MUST NOT
/// throw — the detector swallows exceptions but a slow handler will back
/// up the scan pipeline.
typedef TelemetryHandler = void Function(TelemetryEvent event);
