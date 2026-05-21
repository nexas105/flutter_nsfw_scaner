# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![pub points](https://img.shields.io/pub/points/nsfw_detect)](https://pub.dev/packages/nsfw_detect/score)
[![likes](https://img.shields.io/pub/likes/nsfw_detect)](https://pub.dev/packages/nsfw_detect)
[![platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android-blue)](https://pub.dev/packages/nsfw_detect)
[![license](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Privacy-friendly NSFW detection for Flutter apps. **On-device**, no telemetry, no media uploads.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

final result = await NsfwDetector.instance.scanFile('/path/to/image.jpg');
if (result.isNsfw) {
  // Blur, block, or route to review — your choice.
}
```

That's the whole API for the most common case. No init, no permission for files on disk. Add more entry points as you need them.

> Detection is probabilistic. Use it as a local moderation signal and one layer in a broader safety workflow.

---

## Install

```yaml
dependencies:
  nsfw_detect: ^2.3.0
```

```bash
flutter pub get
```

| Platform | Minimum |
| --- | --- |
| iOS | 16.0+ |
| Android | API 24 / Android 7.0+ |
| Flutter | 3.22+ |
| Dart | 3.4+ |
| Xcode | 15+ |

---

## What you can scan

| Source | API | Permission |
| --- | --- | --- |
| File on disk | `scanFile` · `isNsfwFile` | none |
| Bytes in memory | `scanBytes` · `isNsfwBytes` | none |
| Flutter `ImageProvider` | `scanImageProvider` | none |
| Remote URL | `scanUrl` | none (network) |
| Photo-library asset id | `scanAsset` · `isNsfwAsset` | photo library |
| System picker | `pickMedia` · `pickAndScan` | none (per-item access) |
| Whole library | `startScan` | photo library |
| Live camera | `startCameraScan` | camera |
| Mixed batch | `scanPaths(['file://…', 'https://…', '/abs/path', 'asset-id'])` | per-source |

Each headless API returns a `ScanResult` (full label list + detections) or a shortcut `Future<bool>` via the `isNsfw*` variants.

---

## Common patterns

### Gate an image before display

```dart
NsfwModerationGate.file(
  '/path/to/upload.jpg',
  child: Image.file(File('/path/to/upload.jpg')),
)
```

Constructors: `.bytes(...)`, `.file(...)`, `.asset(...)`. Optional `confidenceFloor` adds a manual-review band; pass `nsfwBuilder` / `uncertainBuilder` / `errorBuilder` for custom UI.

### Pick + scan in one call

```dart
final session = await NsfwDetector.instance.pickAndScan(maxItems: 5);
await for (final r in session.results) {
  if (r.isNsfw) { /* … */ }
}
```

`pickMedia` (returns the picked items without scanning) is the other half of that API.

### Scan a URL before showing it

```dart
final r = await NsfwDetector.instance.scanUrl(
  Uri.parse('https://cdn.example.com/avatar.jpg'),
  timeout: const Duration(seconds: 8),
);
if (r.isNsfw) /* hide / report */
```

Hard-capped at 32 MB by default to keep a malicious server from OOM-ing you. Override via `maxBytes`.

### Find perceptual duplicates

```dart
final clusters = await NsfwDetector.instance.findDuplicates(
  items, // List<MediaItem>
  loadBytes: (id) async => await myStorage.read(id),
);
// clusters: List<List<MediaItem>> — each cluster ≥ 2 visually-identical items.
```

dHash + LRU cache; the detector decouples from your storage layer via `loadBytes`.

### Redact detector boxes in place

```dart
final redacted = await NsfwDetector.instance.redactBytes(
  bytes,
  result,
  mode: RedactionMode.blur, // or .pixelate, .blackBox
  intensity: 0.8,
);
```

When `result.detections` is non-empty, only the per-detection boxes are redacted. Falls back to whole-image redaction for classifier-only results.

### Whole-library scan with progress

```dart
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  const ScanConfiguration.strict(includeVideos: true),
);
if (session == null) return; // User denied — show your permission UI.

session.results.listen((r) { if (r.isNsfw) /* … */ });
session.progress.listen((p) => print('${p.scannedCount}/${p.totalCount}'));
final summary = await session.done;
```

Presets: `.strict()` (threshold 0.85), `.moderate()` (0.7), `.permissive()` (0.5), `.fastScan()` (concurrency 8).

### Pre-warm models on splash

```dart
await NsfwDetector.instance.init(const NsfwInitOptions(
  preloadModels: [ModelIds.openNsfw2],
  enableNativeLogging: false,
));
```

Skipping `init` is fine — the plugin lazy-loads on first use. Use `NsfwInitOptions.lazy()` / `.debug()` / `.production()` for typical shapes.

### Drop-in permissions UI

```dart
NsfwPermissionsView(
  kinds: const [PermissionKind.photoLibrary, PermissionKind.camera],
  onOpenSettings: () => /* host opens system Settings */,
)
```

The plugin doesn't pull in `permission_handler` or `app_settings`; pass `onOpenSettings` to wire your preferred deep-link package.

---

## What's new in 2.3

- **New headless entry points** — `scanUrl`, `scanImageProvider`, `scanPaths` (auto-routing batch).
- **`findDuplicates`** — perceptual-hash duplicate detection; `PerceptualHash.toJson` / `fromJson` for persistence.
- **Native redaction** — `redactBytes` / `redactFile` with `RedactionMode.blur` / `.pixelate` / `.blackBox`.
- **`prefetchAssets`** — pre-warm OS-level asset cache before a `startScan`.
- **`cachedResult` + `cacheUpdates`** — query the on-device scan cache without re-classifying.
- **`NsfwSafetyProfile.evaluate(result)`** — one-call "does this pass at this profile?" check.
- **`NsfwModerationGate.confidenceFloor`** — opt-in uncertainty band between safe / blocked, with `uncertainBuilder` for review UIs.
- **`NsfwScanProgressBar.showEta`** — humanised remaining-time label powered by `ScanProgress.estimatedRemaining`.
- **iOS hardening** — PhotoKit fetches gated by 30 s timeout, resume-once locks on picker / image continuations, scan-task cancellation reaches the video sampler.
- **Android hardening** — `READ_MEDIA_VIDEO` requested + checked together with images on API 33+, start/cancel race fix, https-only + SHA-256-pinned model downloads, zip-bomb defence, engine-detach teardown, OpenNSFW2 is download-on-demand (placeholder asset removed).
- **Detector models in one-shot APIs** — `scanFile` / `scanBytes` / `scanSingleAsset` now route NudeNet through `detectorEngine` and emit `detections` alongside synthetic labels.

Full list in [CHANGELOG.md](CHANGELOG.md).

---

## Result shape

```dart
class ScanResult {
  final MediaItem item;
  final ScanStatus status;       // completed | failed | skipped
  final DateTime scannedAt;
  final List<NsfwLabel> labels;  // sorted: NSFW labels first, then by confidence
  final List<BodyPartDetection> detections; // detector-mode only
  // … convenience getters: isNsfw, topCategory, topConfidence,
  //   hasNudity, hasExplicitContent, isSuggestive, hasDetections,
  //   confidenceDescription
}
```

| Category | `isNsfw` | Typical handling |
| --- | --- | --- |
| `safe` | false | allow |
| `suggestive` | false | optional warning |
| `nudity` | true | block or blur |
| `explicitNudity` | true | block / route to review |
| `unknown` | false | apply your fallback policy |

`result.isNsfw` is true **only** when the scan completed AND the top category is NSFW AND confidence ≥ the threshold.

`ScanResult.toJson()` / `fromJson(...)` round-trip preserves the threshold so `isNsfw` is stable across persistence.

---

## Models

| Id | Shape | Size | Source |
| --- | --- | --- | --- |
| `ModelIds.openNsfw2` | classifier, 224 | ~11 MB | downloaded on first use |
| `ModelIds.falconsai` | classifier, 224 (ViT) | ~75 MB | opt-in download |
| `ModelIds.adamcodd` | classifier, 384 (ViT) | ~75 MB | opt-in download |
| `ModelIds.nudenet` | detector, 640 (YOLOv8m body-parts) | ~46 MB | opt-in download |

Set a custom mirror URL with `setModelUrl(modelId, url)`. The model archive's SHA-256 is verified before extraction when pinned on the descriptor. Manage downloads / preloads via `NsfwDetector.instance.models` (`NsfwModelManager`).

---

## Permissions

| Workflow | iOS | Android |
| --- | --- | --- |
| `scanFile` · `scanBytes` · `scanUrl` · `scanImageProvider` | none | none |
| `pickMedia` · `pickAndScan` | none (picker grants per item) | none |
| `scanAsset` · `startScan` | `NSPhotoLibraryUsageDescription` | `READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO` (API 33+) / `READ_EXTERNAL_STORAGE` (≤32) |
| `startCameraScan` | `NSCameraUsageDescription` | `CAMERA` |

The plugin requests at runtime via `requestPermission` / `requestCameraPermission`. `NsfwPermissionsView` is a drop-in panel showing live status with a Request button.

---

## Documentation

- [Getting started](doc/getting-started.md)
- [Cookbook — common patterns](doc/cookbook.md)
- [Permissions](doc/permissions.md)
- [Media precheck](doc/media-precheck.md)
- [Picker workflows](doc/picker-workflows.md)
- [Library scanning](doc/library-scanning.md)
- [Camera scanning](doc/camera-scanning.md)
- [Configuration](doc/configuration.md)
- [Models](doc/models.md)
- [Platform gotchas (iOS / Android)](doc/platform-gotchas.md)
- [Performance tuning](doc/performance-tuning.md)
- [False positives FAQ](doc/false-positives-faq.md)
- [Privacy and limitations](doc/privacy-and-limitations.md)
- [Troubleshooting](doc/troubleshooting.md)

API reference on [pub.dev](https://pub.dev/documentation/nsfw_detect/latest/).

---

## Example app

```bash
git clone https://github.com/nexas105/flutter_nsfw_scaner.git
cd flutter_nsfw_scaner/example
flutter pub get
flutter run
```

A real device is recommended for photo-library and camera workflows — the iOS simulator has no camera, and emulator photo libraries are usually empty. The example covers the gallery view, picker flow, camera scanner, result detail, moderation gate, and model selection.

---

## Privacy

- Inference runs **on-device** on Core ML (iOS) and TFLite (Android). No analytics, no telemetry.
- Picker-based scanning avoids full photo-library permission — the system picker grants per-item access.
- `scanUrl` is the only Dart-initiated network egress the plugin performs; everything else is local. Model downloads are explicit calls or the auto-download path the host opts into via `NsfwInitOptions.downloadIfMissing`.

Your app remains responsible for explaining permissions, handling results, storing any moderation state, and complying with platform / privacy / safety requirements.

---

## Limitations

NSFW detection is probabilistic. Expect false positives and false negatives on unusual lighting, partial visibility, illustrations, screenshots, low-resolution media, compressed video, or ambiguous content.

Tune `confidenceThreshold` for your product risk. For sensitive workflows, combine on-device detection with user reporting, human review, policy-specific rules, or additional moderation layers.

---

## Links

- [pub.dev package](https://pub.dev/packages/nsfw_detect)
- [API documentation](https://pub.dev/documentation/nsfw_detect/latest/)
- [GitHub repository](https://github.com/nexas105/flutter_nsfw_scaner)
- [Issue tracker](https://github.com/nexas105/flutter_nsfw_scaner/issues)
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
