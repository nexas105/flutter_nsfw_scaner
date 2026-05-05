import 'package:flutter/foundation.dart';

@immutable
class ScanConfiguration {
  final String modelId;
  final double confidenceThreshold;
  final int maxVideoFrames;
  final double videoFrameInterval;
  final bool includeVideos;
  final bool includeLivePhotos;
  final List<String>? assetIdentifiers;
  final bool resumeFromCheckpoint;
  final int concurrency;
  final double detectionConfidenceThreshold;
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
  });

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
      );

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
        if (androidDelegate != null) 'androidDelegate': androidDelegate!.wireValue,
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

    return ScanConfiguration(
      modelId: json['modelId'] as String? ?? defaults.modelId,
      confidenceThreshold:
          (json['confidenceThreshold'] as num?)?.toDouble() ??
              defaults.confidenceThreshold,
      maxVideoFrames:
          (json['maxVideoFrames'] as num?)?.toInt() ?? defaults.maxVideoFrames,
      videoFrameInterval:
          (json['videoFrameInterval'] as num?)?.toDouble() ??
              defaults.videoFrameInterval,
      includeVideos: json['includeVideos'] as bool? ?? defaults.includeVideos,
      includeLivePhotos:
          json['includeLivePhotos'] as bool? ?? defaults.includeLivePhotos,
      assetIdentifiers: parseAssetIds(),
      resumeFromCheckpoint:
          json['resumeFromCheckpoint'] as bool? ?? defaults.resumeFromCheckpoint,
      concurrency:
          (json['concurrency'] as num?)?.toInt() ?? defaults.concurrency,
      detectionConfidenceThreshold:
          (json['detectionConfidenceThreshold'] as num?)?.toDouble() ??
              defaults.detectionConfidenceThreshold,
      iouThreshold: (json['iouThreshold'] as num?)?.toDouble() ??
          defaults.iouThreshold,
      disableBatchPrediction: json['disableBatchPrediction'] as bool? ??
          defaults.disableBatchPrediction,
      skipAlreadyScanned:
          json['skipAlreadyScanned'] as bool? ?? defaults.skipAlreadyScanned,
      forceRescan: json['forceRescan'] as bool? ?? defaults.forceRescan,
      replayCachedResults:
          json['replayCachedResults'] as bool? ?? defaults.replayCachedResults,
      iosComputeUnits: parseCompute(),
      androidDelegate: parseDelegate(),
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
        androidDelegate == other.androidDelegate;
  }

  @override
  int get hashCode => Object.hash(
        modelId,
        confidenceThreshold,
        maxVideoFrames,
        videoFrameInterval,
        includeVideos,
        includeLivePhotos,
        assetIdentifiers == null
            ? null
            : Object.hashAll(assetIdentifiers!),
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
        ),
      );
}

abstract class ModelIds {
  static const String openNsfw2 = 'opennsfw2_coreml';
  static const String falconsai = 'falconsai_nsfw';
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
