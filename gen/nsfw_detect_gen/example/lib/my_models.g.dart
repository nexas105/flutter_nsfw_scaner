// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'my_models.dart';

// **************************************************************************
// NsfwModelGenerator
// **************************************************************************

/// Generated registry for `MyModels`. Do not edit by hand.
class _$MyModelsRegistry {
  const _$MyModelsRegistry();

  /// Stable id for `MyModels.openNsfw2` (threshold 0.6).
  String get openNsfw2 => 'opennsfw2_coreml';

  /// Stable id for `MyModels.nudeNet` (threshold 0.7).
  String get nudeNet => 'nudenet';

  /// Suggested confidence threshold for `openNsfw2`.
  double get openNsfw2Threshold => 0.6;

  /// Suggested confidence threshold for `nudeNet`.
  double get nudeNetThreshold => 0.7;

  /// All annotated models keyed by id.
  Map<String, NsfwModel> get models => const {
        'opennsfw2_coreml': NsfwModel(
          id: 'opennsfw2_coreml',
          defaultThreshold: 0.6,
          defaultMode: ScanMode.classification,
          displayName: 'OpenNSFW 2',
          tags: {'classification', 'open-source'},
        ),
        'nudenet': NsfwModel(
          id: 'nudenet',
          defaultThreshold: 0.7,
          defaultMode: ScanMode.detection,
          displayName: 'NudeNet',
          tags: {'detection', 'permissive-license'},
        ),
      };

  /// Ensures every annotated model is downloaded + loaded.
  Future<void> registerAll(NsfwDetector detector) async {
    await detector.models.ensureReady('opennsfw2_coreml');
    await detector.models.ensureReady('nudenet');
  }
}

/// Convenience singleton — `MyModelsRegistry().models`.
const _$MyModelsRegistry myModelsRegistry = _$MyModelsRegistry();
