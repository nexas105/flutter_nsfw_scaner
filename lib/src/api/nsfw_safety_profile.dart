import 'camera_configuration.dart';
import 'scan_configuration.dart';
import 'scan_mode.dart';

/// Pre-tuned safety profiles bundling a recommended NSFW confidence
/// threshold with a short age-rating label. Use these as a starting point
/// when wiring a moderation gate so you don't have to invent thresholds
/// from scratch.
///
/// Pair with [toScanConfiguration] / [toCameraConfiguration] to drop the
/// profile straight into the scan APIs:
///
/// ```dart
/// final cfg = NsfwSafetyProfile.kidSafe.toScanConfiguration();
/// final session = await NsfwDetector.instance.startScan(cfg);
/// ```
///
/// Thresholds are deliberately conservative — apps that need finer control
/// should override with [toScanConfiguration.confidenceThreshold] or build
/// a `ScanConfiguration` by hand.
enum NsfwSafetyProfile {
  /// Strictest tier. Threshold `0.5` flags any moderate-confidence NSFW
  /// signal. Suitable for kid-safe surfaces / family modes where false
  /// negatives are far more costly than false positives.
  kidSafe(0.5, ageRating: 'all-ages'),

  /// Balanced tier. Threshold `0.7` matches the plugin default — flags
  /// items the model is fairly confident about. Reasonable starting point
  /// for general teen-rated apps.
  teen(0.7, ageRating: 'teen'),

  /// Most permissive tier. Threshold `0.85` only flags items the model is
  /// highly confident about. Suitable for adult-rated surfaces where you
  /// still want to redact the most explicit content but tolerate
  /// suggestive imagery.
  adult(0.85, ageRating: 'adult');

  const NsfwSafetyProfile(
    this.recommendedThreshold, {
    required this.ageRating,
  });

  /// The NSFW confidence threshold associated with this profile.
  final double recommendedThreshold;

  /// Short age-rating label (`'all-ages'` / `'teen'` / `'adult'`). Not
  /// localized — wrap in your own i18n layer if you surface this to users.
  final String ageRating;

  /// Builds a [ScanConfiguration] from this profile. Any `overrides`
  /// passed in win over the profile's defaults.
  ScanConfiguration toScanConfiguration({
    String? modelId,
    double? confidenceThreshold,
    int? maxVideoFrames,
    double? videoFrameInterval,
    bool? includeVideos,
    bool? includeLivePhotos,
    List<String>? assetIdentifiers,
    int? concurrency,
    ScanMode? mode,
  }) =>
      ScanConfiguration(
        modelId: modelId ?? ModelIds.openNsfw2,
        confidenceThreshold: confidenceThreshold ?? recommendedThreshold,
        maxVideoFrames: maxVideoFrames ?? 8,
        videoFrameInterval: videoFrameInterval ?? 2.0,
        includeVideos: includeVideos ?? true,
        includeLivePhotos: includeLivePhotos ?? true,
        assetIdentifiers: assetIdentifiers,
        concurrency: concurrency ?? 4,
        mode: mode ?? ScanMode.classification,
      );

  /// Builds a [CameraConfiguration] from this profile. Any `overrides`
  /// passed in win over the profile's defaults.
  CameraConfiguration toCameraConfiguration({
    String? modelId,
    double? confidenceThreshold,
    ScanMode? mode,
    int? fps,
    CameraResolution? resolution,
  }) =>
      CameraConfiguration(
        modelId: modelId ?? ModelIds.openNsfw2,
        confidenceThreshold: confidenceThreshold ?? recommendedThreshold,
        mode: mode ?? ScanMode.classification,
        fps: fps ?? 2,
        resolution: resolution ?? CameraResolution.medium,
      );
}
