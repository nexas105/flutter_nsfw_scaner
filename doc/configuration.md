# Configuration

`ScanConfiguration` controls library, picker, asset, file, and video scans. `CameraConfiguration` controls live camera scanning.

## Common scan configuration

```dart
const config = ScanConfiguration(
  modelId: ModelIds.openNsfw2,
  mode: ScanMode.classification,
  confidenceThreshold: 0.75,
  includeVideos: true,
  includeLivePhotos: true,
  maxVideoFrames: 8,
  videoFrameInterval: 2.0,
  concurrency: 4,
  skipAlreadyScanned: true,
  replayCachedResults: true,
);
```

## Thresholds

`confidenceThreshold` controls when `ScanResult.isNsfw` becomes true for `nudity` or `explicitNudity`.

```dart
const stricter = ScanConfiguration(confidenceThreshold: 0.85);
const moreSensitive = ScanConfiguration(confidenceThreshold: 0.60);
```

Lower thresholds catch more borderline content but can increase false positives. Higher thresholds reduce false positives but can miss more content.

## Classification vs detection

Classification mode returns top-level category labels.

```dart
const config = ScanConfiguration(
  modelId: ModelIds.openNsfw2,
  mode: ScanMode.classification,
);
```

Detection mode returns bounding boxes and aggregated labels.

```dart
const config = ScanConfiguration(
  modelId: ModelDescriptor.nudenet,
  mode: ScanMode.detection,
  detectionConfidenceThreshold: 0.25,
  iouThreshold: 0.45,
);
```

Choose a model whose kind matches the mode.

## Platform tuning

```dart
const config = ScanConfiguration(
  iosComputeUnits: IosComputeUnits.all,
  androidDelegate: AndroidDelegate.gpu,
);
```

On Android, `gpu` and `nnapi` can improve performance on some devices but may be less stable than CPU. If a delegate fails, the native engine falls back to CPU.

For device-specific iOS diagnostics, you can disable Core ML batch prediction:

```dart
const config = ScanConfiguration(disableBatchPrediction: true);
```

## Persisting configuration

```dart
final json = config.toJson();
final restored = ScanConfiguration.fromJson(json);
```

Unknown persisted values fall back to class defaults.

## Camera configuration

```dart
const camera = CameraConfiguration(
  modelId: ModelIds.openNsfw2,
  confidenceThreshold: 0.75,
  mode: ScanMode.classification,
  fps: 2,
  resolution: CameraResolution.medium,
);
```

`fps` must be between 1 and 30. Keep it low unless your UX needs faster reactions.
