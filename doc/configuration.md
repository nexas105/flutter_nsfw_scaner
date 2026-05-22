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

## Per-category thresholds

`thresholdsByCategory` (added in 2.4.0) overrides the scalar `confidenceThreshold` per NSFW category. Use it to express "block explicit content aggressively but tolerate suggestive" without re-classifying.

```dart
final config = ScanConfiguration.moderate().copyWith(
  thresholdsByCategory: {
    NsfwCategory.explicitNudity: 0.5,  // strict — flag early
    NsfwCategory.nudity: 0.7,
    NsfwCategory.suggestive: 0.95,     // tolerate — only flag near-certain
  },
);
```

`ScanResult.isNsfw` and the category shortcuts (`hasNudity` / `hasExplicitContent` / `isSuggestive`) walk each NSFW-priority label against its own per-category threshold; categories not present in the map fall back to the scalar `confidenceThreshold`. Values are clamped to `[0.0, 1.0]` at construction.

The policy propagates through `ScanSession` and `ScanResult.toJson()` / `fromJson(...)`, so persisted results re-evaluate consistently. To re-score a result already in hand under a new policy — without re-running inference — use `ScanResult.withThresholds(...)`:

```dart
final restrict = result.withThresholds({NsfwCategory.suggestive: 0.6});
if (restrict.isSuggestive) { /* ... */ }
```

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

Choose a model whose kind matches the mode. `ModelDescriptor.nudenet` is the bundled detector id; `ModelIds.openNsfw2` / `.falconsai` / `.adamcodd` are classifiers.

`ScanMode.detectThenClassify` (added in 2.4.0) runs the detector first and classifies every emitted crop, attaching per-region labels to each `BodyPartDetection`. The dedicated entry points `scanFileDetectThenClassify` / `scanBytesDetectThenClassify` are the simplest way to use it — see the [models guide](models.md#detect-then-classify) and the [cookbook](cookbook.md#detect-then-classify-each-region).

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
