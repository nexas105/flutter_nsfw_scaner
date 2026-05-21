import 'package:flutter/foundation.dart';

import 'scan_mode.dart';
import 'scan_region.dart';

/// Immutable options for a photo-library NSFW scan.
///
/// A configuration selects the model, scan mode, media types, thresholds, and
/// native performance hints used by `NsfwDetector.startScan` and picker-based
/// scans. Classification and detection thresholds influence convenience
/// decisions such as `ScanResult.isNsfw`; they do not make the model output
/// deterministic or authoritative.
///
/// The default values favor broad library coverage with on-device processing,
/// cache reuse, and conservative throughput. Increase concurrency and delegate
/// settings only after testing on the device families you support.
@immutable
class ScanConfiguration {
  /// Native model identifier to use for this scan.
  final String modelId;

  /// Minimum top-label confidence required for `ScanResult.isNsfw`.
  final double confidenceThreshold;

  /// Maximum number of frames sampled from each video asset.
  final int maxVideoFrames;

  /// Target spacing, in seconds, between sampled video frames.
  final double videoFrameInterval;

  /// Whether video assets are included in the library scan.
  final bool includeVideos;

  /// Whether Live Photos are included when the platform exposes them.
  final bool includeLivePhotos;

  /// Optional fixed set of photo-library asset identifiers to scan.
  ///
  /// Leave null to scan the library subset implied by the permission grant and
  /// media-type flags.
  final List<String>? assetIdentifiers;

  /// Whether the native scanner should resume from its last checkpoint.
  final bool resumeFromCheckpoint;

  /// Maximum number of assets the native implementation may classify in
  /// parallel.
  final int concurrency;

  /// Per-box confidence threshold used by detection models.
  final double detectionConfidenceThreshold;

  /// Intersection-over-union threshold used for non-maximum suppression in
  /// detection mode.
  final double iouThreshold;

  /// Kill switch for CoreML batch prediction. Set to `true` to revert to the
  /// serial per-image Vision path. Useful for diagnosing device-specific issues.
  final bool disableBatchPrediction;

  /// Skip assets whose `(localId, modelId, modificationDate)` match a cached entry.
  /// Default `true` — re-syncing a 200k-asset library becomes a sub-second filter
  /// instead of a full ML pass.
  final bool skipAlreadyScanned;

  /// Bypass the cache for this run — every asset is re-scanned and the cache is
  /// overwritten. Useful for "rescan all" buttons.
  final bool forceRescan;

  /// When `skipAlreadyScanned` triggers a hit, replay the cached classification as
  /// a normal `ScanResult` so the stream stays complete. Disable for delta mode.
  final bool replayCachedResults;

  /// iOS only — selects `MLModelConfiguration.computeUnits`. On older devices
  /// without dedicated ANE, `cpuAndNeuralEngine` or `cpuOnly` can outperform `all`.
  /// Allowed: `all` (default), `cpuAndNeuralEngine`, `cpuAndGPU`, `cpuOnly`.
  final IosComputeUnits iosComputeUnits;

  /// Android only — opt-in TFLite delegate. `null` = CPU (default, safest).
  /// `gpu` and `nnapi` can be 3–10× faster on modern devices but may be unstable
  /// on some device families; the engine falls back to CPU if the delegate fails.
  final AndroidDelegate? androidDelegate;

  /// Selects which native ML pipeline runs per asset. Default is
  /// [ScanMode.classification] — Top-level NSFW classifier categories.
  /// [ScanMode.detection] swaps in a NudeNet-style bounding-box detector and
  /// populates `ScanResult.detections`. Choose a `modelId` whose registered
  /// kind matches the requested mode.
  final ScanMode mode;

  /// Single normalized region (`x`, `y`, `width`, `height` in `[0, 1]`) that
  /// the native scanner should crop before classifying each asset. `null`
  /// means scan the full image. Applied to every asset in a library scan.
  final ScanRegion? region;

  /// Asset identifiers to skip in this scan. Useful for moderation review
  /// queues that have already triaged a subset of the library. Native side
  /// SHOULD honour this if supported; the Dart-side [ScanSession] filters
  /// matching `localId` events as a defensive fallback.
  ///
  /// Precedence: if [includeOnlyAssetIds] is non-empty it wins — any id not
  /// in the include set is skipped, regardless of this set.
  final Set<String> skipAssetIds;

  /// When non-empty, only assets whose `localId` is in this set are scanned.
  /// Combined precedence with [skipAssetIds]: include-only wins.
  final Set<String> includeOnlyAssetIds;

  const ScanConfiguration({
    this.modelId = ModelIds.openNsfw2,
    this.confidenceThreshold = 0.7,
    this.maxVideoFrames = 8,
    this.videoFrameInterval = 2.0,
    this.includeVideos = true,
    this.includeLivePhotos = true,
    this.assetIdentifiers,
    this.resumeFromCheckpoint = false,
    this.concurrency = 4,
    this.detectionConfidenceThreshold = 0.25,
    this.iouThreshold = 0.45,
    this.disableBatchPrediction = false,
    this.skipAlreadyScanned = true,
    this.forceRescan = false,
    this.replayCachedResults = true,
    this.iosComputeUnits = IosComputeUnits.all,
    this.androidDelegate,
    this.mode = ScanMode.classification,
    this.region,
    this.skipAssetIds = const {},
    this.includeOnlyAssetIds = const {},
  })  : assert(
          confidenceThreshold >= 0.0 && confidenceThreshold <= 1.0,
          'confidenceThreshold must be in [0.0, 1.0]',
        ),
        assert(
          detectionConfidenceThreshold >= 0.0 &&
              detectionConfidenceThreshold <= 1.0,
          'detectionConfidenceThreshold must be in [0.0, 1.0]',
        ),
        assert(
          iouThreshold >= 0.0 && iouThreshold <= 1.0,
          'iouThreshold must be in [0.0, 1.0]',
        );

  /// Strict moderation tuning — high `confidenceThreshold` (0.85) so only
  /// strong NSFW signals trip `isNsfw`. Lower false-positive cost is traded
  /// for slightly higher false-negative risk.
  const ScanConfiguration.strict({
    String modelId = ModelIds.openNsfw2,
    bool includeVideos = true,
    bool includeLivePhotos = true,
    List<String>? assetIdentifiers,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: 0.85,
          includeVideos: includeVideos,
          includeLivePhotos: includeLivePhotos,
          assetIdentifiers: assetIdentifiers,
          mode: mode,
        );

  /// Balanced default — `confidenceThreshold` 0.7, cache on. Good starting
  /// point for general moderation workflows.
  const ScanConfiguration.moderate({
    String modelId = ModelIds.openNsfw2,
    bool includeVideos = true,
    bool includeLivePhotos = true,
    List<String>? assetIdentifiers,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: 0.7,
          includeVideos: includeVideos,
          includeLivePhotos: includeLivePhotos,
          assetIdentifiers: assetIdentifiers,
          mode: mode,
        );

  /// Permissive tuning — `confidenceThreshold` 0.5. Flags more items.
  /// Useful for review queues where false negatives are costlier than
  /// false positives.
  const ScanConfiguration.permissive({
    String modelId = ModelIds.openNsfw2,
    bool includeVideos = true,
    bool includeLivePhotos = true,
    List<String>? assetIdentifiers,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: 0.5,
          includeVideos: includeVideos,
          includeLivePhotos: includeLivePhotos,
          assetIdentifiers: assetIdentifiers,
          mode: mode,
        );

  /// Throughput-tuned preset — higher `concurrency` (8) and skips already
  /// scanned items. Use after profiling on the device families you support.
  const ScanConfiguration.fastScan({
    String modelId = ModelIds.openNsfw2,
    double confidenceThreshold = 0.7,
    bool includeVideos = true,
    bool includeLivePhotos = true,
    List<String>? assetIdentifiers,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          includeVideos: includeVideos,
          includeLivePhotos: includeLivePhotos,
          assetIdentifiers: assetIdentifiers,
          concurrency: 8,
          skipAlreadyScanned: true,
          mode: mode,
        );

  /// Returns a copy with selected fields replaced.
  ///
  /// Passing null leaves the existing value unchanged.
  ScanConfiguration copyWith({
    String? modelId,
    double? confidenceThreshold,
    int? maxVideoFrames,
    double? videoFrameInterval,
    bool? includeVideos,
    bool? includeLivePhotos,
    List<String>? assetIdentifiers,
    bool? resumeFromCheckpoint,
    int? concurrency,
    double? detectionConfidenceThreshold,
    double? iouThreshold,
    bool? disableBatchPrediction,
    bool? skipAlreadyScanned,
    bool? forceRescan,
    bool? replayCachedResults,
    IosComputeUnits? iosComputeUnits,
    AndroidDelegate? androidDelegate,
    ScanMode? mode,
    ScanRegion? region,
    Set<String>? skipAssetIds,
    Set<String>? includeOnlyAssetIds,
  }) =>
      ScanConfiguration(
        modelId: modelId ?? this.modelId,
        confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
        maxVideoFrames: maxVideoFrames ?? this.maxVideoFrames,
        videoFrameInterval: videoFrameInterval ?? this.videoFrameInterval,
        includeVideos: includeVideos ?? this.includeVideos,
        includeLivePhotos: includeLivePhotos ?? this.includeLivePhotos,
        assetIdentifiers: assetIdentifiers ?? this.assetIdentifiers,
        resumeFromCheckpoint: resumeFromCheckpoint ?? this.resumeFromCheckpoint,
        concurrency: concurrency ?? this.concurrency,
        detectionConfidenceThreshold:
            detectionConfidenceThreshold ?? this.detectionConfidenceThreshold,
        iouThreshold: iouThreshold ?? this.iouThreshold,
        disableBatchPrediction:
            disableBatchPrediction ?? this.disableBatchPrediction,
        skipAlreadyScanned: skipAlreadyScanned ?? this.skipAlreadyScanned,
        forceRescan: forceRescan ?? this.forceRescan,
        replayCachedResults: replayCachedResults ?? this.replayCachedResults,
        iosComputeUnits: iosComputeUnits ?? this.iosComputeUnits,
        androidDelegate: androidDelegate ?? this.androidDelegate,
        mode: mode ?? this.mode,
        region: region ?? this.region,
        skipAssetIds: skipAssetIds ?? this.skipAssetIds,
        includeOnlyAssetIds: includeOnlyAssetIds ?? this.includeOnlyAssetIds,
      );

  /// Converts this configuration into the method-channel payload expected by
  /// the native implementations.
  Map<String, dynamic> toChannelMap() => {
        'modelId': modelId,
        'confidenceThreshold': confidenceThreshold,
        'maxVideoFrames': maxVideoFrames,
        'videoFrameInterval': videoFrameInterval,
        'includeVideos': includeVideos,
        'includeLivePhotos': includeLivePhotos,
        if (assetIdentifiers != null) 'assetIdentifiers': assetIdentifiers,
        'resumeFromCheckpoint': resumeFromCheckpoint,
        'concurrency': concurrency,
        'detectionConfidenceThreshold': detectionConfidenceThreshold,
        'iouThreshold': iouThreshold,
        'disableBatchPrediction': disableBatchPrediction,
        'skipAlreadyScanned': skipAlreadyScanned,
        'forceRescan': forceRescan,
        'replayCachedResults': replayCachedResults,
        'iosComputeUnits': iosComputeUnits.wireValue,
        if (androidDelegate != null)
          'androidDelegate': androidDelegate!.wireValue,
        'mode': mode.wireValue,
        if (region != null) 'roi': region!.toJson(),
        if (skipAssetIds.isNotEmpty) 'skipAssetIds': skipAssetIds.toList(),
        if (includeOnlyAssetIds.isNotEmpty)
          'includeOnlyAssetIds': includeOnlyAssetIds.toList(),
      };

  /// Serialises the configuration to a JSON-safe map. Symmetric with
  /// [ScanConfiguration.fromJson]. Use this for persistence (e.g.
  /// `shared_preferences`).
  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        'confidenceThreshold': confidenceThreshold,
        'maxVideoFrames': maxVideoFrames,
        'videoFrameInterval': videoFrameInterval,
        'includeVideos': includeVideos,
        'includeLivePhotos': includeLivePhotos,
        if (assetIdentifiers != null) 'assetIdentifiers': assetIdentifiers,
        'resumeFromCheckpoint': resumeFromCheckpoint,
        'concurrency': concurrency,
        'detectionConfidenceThreshold': detectionConfidenceThreshold,
        'iouThreshold': iouThreshold,
        'disableBatchPrediction': disableBatchPrediction,
        'skipAlreadyScanned': skipAlreadyScanned,
        'forceRescan': forceRescan,
        'replayCachedResults': replayCachedResults,
        'iosComputeUnits': iosComputeUnits.wireValue,
        if (androidDelegate != null)
          'androidDelegate': androidDelegate!.wireValue,
        'mode': mode.wireValue,
        if (region != null) 'region': region!.toJson(),
        if (skipAssetIds.isNotEmpty) 'skipAssetIds': skipAssetIds.toList(),
        if (includeOnlyAssetIds.isNotEmpty)
          'includeOnlyAssetIds': includeOnlyAssetIds.toList(),
      };

  /// Restores a configuration previously produced by [toJson]. Unknown values
  /// fall back to the defaults declared on the class.
  factory ScanConfiguration.fromJson(Map<String, dynamic> json) {
    const defaults = ScanConfiguration();

    IosComputeUnits parseCompute() {
      final v = json['iosComputeUnits'];
      if (v is! String) return defaults.iosComputeUnits;
      return IosComputeUnits.values.firstWhere(
        (e) => e.wireValue == v,
        orElse: () => defaults.iosComputeUnits,
      );
    }

    AndroidDelegate? parseDelegate() {
      final v = json['androidDelegate'];
      if (v is! String) return null;
      for (final d in AndroidDelegate.values) {
        if (d.wireValue == v) return d;
      }
      return null;
    }

    List<String>? parseAssetIds() {
      final v = json['assetIdentifiers'];
      if (v is! List) return null;
      return v.whereType<String>().toList(growable: false);
    }

    Set<String> parseStringSet(String key) {
      final v = json[key];
      if (v is! List) return const {};
      return v.whereType<String>().toSet();
    }

    ScanRegion? parseRegion() {
      final v = json['region'];
      if (v is Map<dynamic, dynamic>) return ScanRegion.fromJson(v);
      return null;
    }

    return ScanConfiguration(
      modelId: json['modelId'] as String? ?? defaults.modelId,
      confidenceThreshold: (json['confidenceThreshold'] as num?)?.toDouble() ??
          defaults.confidenceThreshold,
      maxVideoFrames:
          (json['maxVideoFrames'] as num?)?.toInt() ?? defaults.maxVideoFrames,
      videoFrameInterval: (json['videoFrameInterval'] as num?)?.toDouble() ??
          defaults.videoFrameInterval,
      includeVideos: json['includeVideos'] as bool? ?? defaults.includeVideos,
      includeLivePhotos:
          json['includeLivePhotos'] as bool? ?? defaults.includeLivePhotos,
      assetIdentifiers: parseAssetIds(),
      resumeFromCheckpoint: json['resumeFromCheckpoint'] as bool? ??
          defaults.resumeFromCheckpoint,
      concurrency:
          (json['concurrency'] as num?)?.toInt() ?? defaults.concurrency,
      detectionConfidenceThreshold:
          (json['detectionConfidenceThreshold'] as num?)?.toDouble() ??
              defaults.detectionConfidenceThreshold,
      iouThreshold:
          (json['iouThreshold'] as num?)?.toDouble() ?? defaults.iouThreshold,
      disableBatchPrediction: json['disableBatchPrediction'] as bool? ??
          defaults.disableBatchPrediction,
      skipAlreadyScanned:
          json['skipAlreadyScanned'] as bool? ?? defaults.skipAlreadyScanned,
      forceRescan: json['forceRescan'] as bool? ?? defaults.forceRescan,
      replayCachedResults:
          json['replayCachedResults'] as bool? ?? defaults.replayCachedResults,
      iosComputeUnits: parseCompute(),
      androidDelegate: parseDelegate(),
      mode: ScanMode.fromWire(json['mode'] as String?),
      region: parseRegion(),
      skipAssetIds: parseStringSet('skipAssetIds'),
      includeOnlyAssetIds: parseStringSet('includeOnlyAssetIds'),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ScanConfiguration) return false;
    return modelId == other.modelId &&
        confidenceThreshold == other.confidenceThreshold &&
        maxVideoFrames == other.maxVideoFrames &&
        videoFrameInterval == other.videoFrameInterval &&
        includeVideos == other.includeVideos &&
        includeLivePhotos == other.includeLivePhotos &&
        listEquals(assetIdentifiers, other.assetIdentifiers) &&
        resumeFromCheckpoint == other.resumeFromCheckpoint &&
        concurrency == other.concurrency &&
        detectionConfidenceThreshold == other.detectionConfidenceThreshold &&
        iouThreshold == other.iouThreshold &&
        disableBatchPrediction == other.disableBatchPrediction &&
        skipAlreadyScanned == other.skipAlreadyScanned &&
        forceRescan == other.forceRescan &&
        replayCachedResults == other.replayCachedResults &&
        iosComputeUnits == other.iosComputeUnits &&
        androidDelegate == other.androidDelegate &&
        mode == other.mode &&
        region == other.region &&
        setEquals(skipAssetIds, other.skipAssetIds) &&
        setEquals(includeOnlyAssetIds, other.includeOnlyAssetIds);
  }

  @override
  int get hashCode => Object.hash(
        modelId,
        confidenceThreshold,
        maxVideoFrames,
        videoFrameInterval,
        includeVideos,
        includeLivePhotos,
        assetIdentifiers == null ? null : Object.hashAll(assetIdentifiers!),
        resumeFromCheckpoint,
        concurrency,
        detectionConfidenceThreshold,
        iouThreshold,
        Object.hash(
          disableBatchPrediction,
          skipAlreadyScanned,
          forceRescan,
          replayCachedResults,
          iosComputeUnits,
          androidDelegate,
          mode,
          region,
          Object.hashAllUnordered(skipAssetIds),
          Object.hashAllUnordered(includeOnlyAssetIds),
        ),
      );
}

abstract class ModelIds {
  /// Default OpenNSFW2 classifier model.
  static const String openNsfw2 = 'opennsfw2_coreml';

  /// FalconsAI NSFW classifier model.
  static const String falconsai = 'falconsai_nsfw';

  /// AdamCodd NSFW classifier model.
  static const String adamcodd = 'adamcodd_nsfw';
}

/// iOS Core ML compute-unit preference. Mirrors `MLComputeUnits`.
enum IosComputeUnits {
  all('all'),
  cpuAndNeuralEngine('cpuAndNeuralEngine'),
  cpuAndGPU('cpuAndGPU'),
  cpuOnly('cpuOnly');

  const IosComputeUnits(this.wireValue);
  final String wireValue;
}

/// Android TFLite delegate preference. `null` = CPU (default).
enum AndroidDelegate {
  gpu('gpu'),
  nnapi('nnapi');

  const AndroidDelegate(this.wireValue);
  final String wireValue;
}
