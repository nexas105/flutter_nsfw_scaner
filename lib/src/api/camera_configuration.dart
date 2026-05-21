import 'package:flutter/foundation.dart';

import 'scan_configuration.dart';
import 'scan_mode.dart';

/// Resolution preset for the live camera feed.
enum CameraResolution {
  low('low'),
  medium('medium'),
  high('high');

  const CameraResolution(this.wireValue);
  final String wireValue;
}

/// Configuration for a live camera scan session.
///
/// Reuses [ScanMode] and [ModelIds] from the library-scan API so the same
/// models (classification + NudeNet detection) work in camera mode. Camera
/// frames are processed on device by the native implementation, but frame
/// labels are still probabilistic model outputs and should be interpreted with
/// product-specific thresholds and user controls.
@immutable
class CameraConfiguration {
  /// Model to run per frame. Default: [ModelIds.openNsfw2].
  final String modelId;

  /// NSFW confidence threshold used for `CameraFrameResult.isNsfw`.
  final double confidenceThreshold;

  /// Classification vs detection mode.
  /// Detection mode populates `CameraFrameResult.detections`.
  final ScanMode mode;

  /// Target frames-per-second for inference.
  /// Frames are dropped to keep the rate at or below this value.
  /// Range: 1–30. Default: 2.
  final int fps;

  /// Camera capture resolution preset.
  /// Maps to native capture session preset / camera resolution.
  /// Default: [CameraResolution.medium].
  final CameraResolution resolution;

  /// Per-box confidence threshold for NudeNet detector.
  /// Only relevant when [mode] is [ScanMode.detection].
  final double detectionConfidenceThreshold;

  /// Non-maximum suppression IoU threshold for NudeNet detector.
  /// Only relevant when [mode] is [ScanMode.detection].
  final double iouThreshold;

  /// iOS Core ML compute units.
  final IosComputeUnits iosComputeUnits;

  /// Android TFLite delegate.
  final AndroidDelegate? androidDelegate;

  const CameraConfiguration({
    this.modelId = ModelIds.openNsfw2,
    this.confidenceThreshold = 0.7,
    this.mode = ScanMode.classification,
    this.fps = 2,
    this.resolution = CameraResolution.medium,
    this.detectionConfidenceThreshold = 0.25,
    this.iouThreshold = 0.45,
    this.iosComputeUnits = IosComputeUnits.all,
    this.androidDelegate,
  }) : assert(fps >= 1 && fps <= 30, 'fps must be between 1 and 30');

  /// Higher-throughput preset — 10 FPS, high resolution, all compute units.
  /// Best for interactive review apps; expect higher battery draw.
  const CameraConfiguration.realtime({
    String modelId = ModelIds.openNsfw2,
    double confidenceThreshold = 0.7,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          mode: mode,
          fps: 10,
          resolution: CameraResolution.high,
        );

  /// Balanced default — 2 FPS, medium resolution. Identical to the default
  /// constructor, kept as a discoverable alias next to the other presets.
  const CameraConfiguration.balanced({
    String modelId = ModelIds.openNsfw2,
    double confidenceThreshold = 0.7,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          mode: mode,
        );

  /// Low-throughput preset — 1 FPS, low resolution. Good for always-on
  /// background monitoring with minimal battery cost.
  const CameraConfiguration.batteryEfficient({
    String modelId = ModelIds.openNsfw2,
    double confidenceThreshold = 0.7,
    ScanMode mode = ScanMode.classification,
  }) : this(
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          mode: mode,
          fps: 1,
          resolution: CameraResolution.low,
        );

  /// Returns a copy with selected fields replaced.
  ///
  /// Passing null leaves the existing value unchanged.
  CameraConfiguration copyWith({
    String? modelId,
    double? confidenceThreshold,
    ScanMode? mode,
    int? fps,
    CameraResolution? resolution,
    double? detectionConfidenceThreshold,
    double? iouThreshold,
    IosComputeUnits? iosComputeUnits,
    AndroidDelegate? androidDelegate,
  }) =>
      CameraConfiguration(
        modelId: modelId ?? this.modelId,
        confidenceThreshold: confidenceThreshold ?? this.confidenceThreshold,
        mode: mode ?? this.mode,
        fps: fps ?? this.fps,
        resolution: resolution ?? this.resolution,
        detectionConfidenceThreshold:
            detectionConfidenceThreshold ?? this.detectionConfidenceThreshold,
        iouThreshold: iouThreshold ?? this.iouThreshold,
        iosComputeUnits: iosComputeUnits ?? this.iosComputeUnits,
        androidDelegate: androidDelegate ?? this.androidDelegate,
      );

  /// Converts this configuration into the method-channel payload expected by
  /// the native camera scanner.
  Map<String, dynamic> toChannelMap() => {
        'modelId': modelId,
        'confidenceThreshold': confidenceThreshold,
        'mode': mode.wireValue,
        'fps': fps,
        'resolution': resolution.wireValue,
        'detectionConfidenceThreshold': detectionConfidenceThreshold,
        'iouThreshold': iouThreshold,
        'iosComputeUnits': iosComputeUnits.wireValue,
        if (androidDelegate != null)
          'androidDelegate': androidDelegate!.wireValue,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CameraConfiguration) return false;
    return modelId == other.modelId &&
        confidenceThreshold == other.confidenceThreshold &&
        mode == other.mode &&
        fps == other.fps &&
        resolution == other.resolution &&
        detectionConfidenceThreshold == other.detectionConfidenceThreshold &&
        iouThreshold == other.iouThreshold &&
        iosComputeUnits == other.iosComputeUnits &&
        androidDelegate == other.androidDelegate;
  }

  @override
  int get hashCode => Object.hash(
        modelId,
        confidenceThreshold,
        mode,
        fps,
        resolution,
        detectionConfidenceThreshold,
        iouThreshold,
        iosComputeUnits,
        androidDelegate,
      );
}
