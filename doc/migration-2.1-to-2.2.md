# Migration: 2.1.x → 2.2.0

`nsfw_detect` 2.2.0 is fully additive. Existing 2.1.x code keeps compiling and behaving the same. The migrations below are optional adoptions of the new APIs — pick the ones that match your product.

## Init / preload lifecycle

Move per-call cold-start latency to a single bootstrap point.

Before (2.1.x — implicit lazy load on first scan):

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}
```

After (2.2.0):

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NsfwDetector.instance.init(NsfwInitOptions(
    preloadModels: [ModelIds.openNsfw2],
    enableNativeLogging: kDebugMode,
    defaultThreshold: 0.75,
  ));
  runApp(const MyApp());
}
```

`init` is idempotent and safe to call from multiple bootstrap paths. Use `NsfwInitOptions.lazy()` or `.debug()` for the common shapes, and `NsfwDetector.reinit(options)` to swap models or toggle logging at runtime.

## Configuration presets

Stop hand-tuning thresholds for every scan call.

Before:

```dart
final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(
    confidenceThreshold: 0.85,
    includeVideos: true,
  ),
);
```

After:

```dart
final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration.strict(includeVideos: true),
);
```

Available presets:

| Preset | Threshold | Use case |
| --- | --- | --- |
| `ScanConfiguration.strict()` | 0.85 | Pre-publish gates, child-safety surfaces |
| `ScanConfiguration.moderate()` | 0.70 | Default user-content moderation |
| `ScanConfiguration.permissive()` | 0.50 | Aggressive flag-everything review queue |
| `ScanConfiguration.fastScan()` | 0.70, concurrency 8 | First-pass library sweep |

`CameraConfiguration.realtime()`, `.balanced()`, and `.batteryEfficient()` cover the equivalent camera shapes.

## Batch APIs

Replace ad-hoc `for` loops with the new batch helpers — they surface per-item failures as `ScanResult.failed(...)` instead of throwing, so the batch always completes.

Before:

```dart
final results = <ScanResult>[];
for (final path in paths) {
  try {
    results.add(await NsfwDetector.instance.scanFile(path));
  } catch (e) {
    // Bespoke error handling
  }
}
```

After:

```dart
final results = await NsfwDetector.instance.scanFiles(
  paths,
  confidenceThreshold: 0.75,
  onProgress: (done, total) =>
      debugPrint('$done/$total'),
);
final failed = results.failedOnly;
```

`scanAssets(localIds, ...)` and `scanAllBytes(bytesList, ...)` follow the same shape.

## One-shot boolean checks

If you only need a yes/no answer, skip the `ScanResult` plumbing:

```dart
if (await NsfwDetector.instance.isNsfwFile(path)) {
  // Block or blur
}
```

Available shortcuts: `isNsfwFile`, `isNsfwBytes`, `isNsfwAsset`.

## Permission + scan in one call

Before:

```dart
final status = await NsfwDetector.instance.requestPermission();
if (status != PhotoLibraryPermissionStatus.authorized &&
    status != PhotoLibraryPermissionStatus.limited) {
  return;
}
final session = await NsfwDetector.instance.startScan(config);
```

After:

```dart
final session = await NsfwDetector.instance
    .requestPermissionAndStartScan(config);
if (session == null) {
  // User denied — show your permission UI.
  return;
}
```

## Moderation gate widget

Wrap any image-rendering widget; it blurs and overlays a warning when the scan flips NSFW.

```dart
NsfwModerationGate.bytes(
  imageBytes,
  child: Image.memory(imageBytes),
  onResult: (r) => debugPrint(r.topCategory.name),
)
```

Constructors: `.bytes(...)`, `.file(...)`, `.asset(...)`. Customise via `nsfwBuilder`, `errorBuilder`, `loading`. Fails open by default; pass an `errorBuilder` that hides the child to fail closed.

## Permission status helpers

`PhotoLibraryPermissionStatus` gained ergonomic getters so you stop repeating the same branch:

```dart
final status = await NsfwDetector.instance.checkPermission();
if (status.canScan) { /* authorized OR limited */ }
if (status.needsSettingsApp) { /* denied OR restricted */ }
```

`ScanResult` gained category-specific booleans (`hasNudity`, `hasExplicitContent`, `isSuggestive`, `hasDetections`) on top of the existing `isNsfw`, plus a `confidenceDescription` bucket string for debug UIs.
