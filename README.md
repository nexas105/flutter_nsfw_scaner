# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![pub points](https://img.shields.io/pub/points/nsfw_detect)](https://pub.dev/packages/nsfw_detect/score)
[![likes](https://img.shields.io/pub/likes/nsfw_detect)](https://pub.dev/packages/nsfw_detect)
[![platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android-blue)](https://pub.dev/packages/nsfw_detect)
[![license](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Privacy-friendly NSFW detection for Flutter apps. **On-device**, no telemetry, no media uploads.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

// Works for images, videos, GIFs — same call, same result shape.
final result = await NsfwDetector.instance.scanFile('/path/to/file.jpg');
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
  nsfw_detect: ^2.5.3
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
| Image file on disk | `scanFile` · `isNsfwFile` | none |
| **Video file on disk** (mp4, mov, …) | `scanFile` · `isNsfwFile` | none |
| Animated image (gif, apng, webp) | `scanFile` | none |
| Bytes in memory | `scanBytes` · `isNsfwBytes` | none |
| Flutter `ImageProvider` | `scanImageProvider` | none |
| Remote URL (image or video) | `scanUrl` | none (network) |
| Photo-library asset (image **or video**) | `scanAsset` · `isNsfwAsset` | photo library |
| System picker (image **or video**) | `pickMedia` · `pickAndScan` | none (per-item access) |
| Whole library (photos **+ videos**) | `startScan` | photo library |
| Live camera | `startCameraScan` | camera |
| Mixed batch | `scanPaths(['file://…', 'https://…', '/abs/path', 'asset-id'])` | per-source |

**Videos are first-class.** `scanFile` auto-detects the container and samples frames at a configurable interval. No separate API or model is needed.

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

### Scan a video file

```dart
final result = await NsfwDetector.instance.scanFile('/path/to/clip.mp4');
if (result.isNsfw) {
  // result.topCategory, result.topConfidence — same shape as image scans.
}
```

The same API works for `.mov`, `.gif`, `.apng`, and `.webp`. The plugin samples frames automatically and aggregates them into one `ScanResult`. Control the sampling with `ScanConfiguration`:

```dart
final result = await NsfwDetector.instance.scanFile(
  '/path/to/clip.mp4',
  configuration: const ScanConfiguration(
    maxVideoFrames: 12,       // default 8 — more frames, more accurate
    videoFrameInterval: 1.0,  // default 2.0 s — sample every second
  ),
);
```

### Whole-library scan with progress

```dart
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  // includeVideos: true is the default — shown explicitly for clarity.
  const ScanConfiguration.strict(includeVideos: true),
);
if (session == null) return; // User denied — show your permission UI.

session.results.listen((r) { if (r.isNsfw) /* … */ });
session.progress.listen((p) => print('${p.scannedCount}/${p.totalCount}'));
final summary = await session.done;
```

Presets: `.strict()` (threshold 0.85), `.moderate()` (0.7), `.permissive()` (0.5), `.fastScan()` (concurrency 8). Pass `includeVideos: false` to skip video assets and scan images only.

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

### Per-category thresholds

```dart
final config = ScanConfiguration.moderate().copyWith(
  thresholdsByCategory: {
    NsfwCategory.explicitNudity: 0.5,  // flag aggressively
    NsfwCategory.suggestive: 0.95,     // tolerate
  },
);
```

Overrides the scalar `confidenceThreshold` per category; unmapped categories fall back to it. `ScanResult.withThresholds(...)` re-evaluates a persisted result without re-running inference.

### Remember moderator decisions

```dart
NsfwDetector.instance.useDecisionStore(SharedPreferencesDecisionStore());
await NsfwDetector.instance.decisions.mark('asset-id', ScanDecision.allow);
// Later scans of that asset come back with `userDecision` applied —
// .allow forces isNsfw=false, .block forces isNsfw=true.
```

`InMemoryDecisionStore` is the dependency-free default; `SharedPreferencesDecisionStore` persists across cold starts.

### Detect, then classify each region

```dart
final r = await NsfwDetector.instance.scanFileDetectThenClassify(
  '/path/to/image.jpg',
  detectorModelId: ModelDescriptor.nudenet,
);
// r.detections[i].labels — per-region NSFW classification, stronger than
// detector-only (graded confidence) or classifier-only (per-region attribution).
```

### Telemetry hooks

```dart
NsfwDetector.instance.onTelemetryEvent = (e) => myAnalytics.log(e);
```

Structured `scanCompleted` / `modelLoaded` / `downloadFinished` / … events with timing and a PII-free confidence decile. `localId` only attaches when `includeLocalIdsInTelemetry` is set. The plugin itself sends nothing — this is a local callback.

### Localize plugin strings

```dart
NsfwLocalizations.current = const NsfwLocalizationsDe();
```

Bundled EN/DE/ES/FR/JA cover category names, permission hints, confidence buckets, and widget button labels. `NsfwLocalizations.resolve('es-MX')` picks a bundle by BCP-47 tag.

---

## What's new

**2.5.x — platform reach + polish**

- **Localization** — `NsfwLocalizations` plain-Dart bundle (EN/DE/ES/FR/JA), no new deps. Global override via `NsfwLocalizations.current`.
- **Accessibility** — Semantics pass over the surfaced widgets; WCAG-AA badge contrast via `NsfwGalleryTheme.readableForeground`.

**2.4.0 — architectural moves**

- **Detect-then-classify pipeline** — `ScanMode.detectThenClassify`, `scanBytesDetectThenClassify` / `scanFileDetectThenClassify`; per-region labels on `BodyPartDetection.labels`.
- **Per-category thresholds** — `ScanConfiguration.thresholdsByCategory`, `ScanResult.withThresholds`.
- **Persistent decision store** — `DecisionStore` (`InMemory*` / `SharedPreferences*`), `NsfwDetector.decisions`, `ScanResult.userDecision`.
- **Telemetry hooks** — `NsfwDetector.onTelemetryEvent`, PII-free by default.
- **Evaluation harness** — `tools/eval/` precision / recall / F1 reporting + a false-positive regression suite.

**2.3.0 — headless inputs + redaction**

- `scanUrl`, `scanImageProvider`, `scanPaths` (auto-routing batch); `findDuplicates` + `PerceptualHash` JSON.
- Native redaction — `redactBytes` / `redactFile` with `RedactionMode.blur` / `.pixelate` / `.blackBox`.
- `prefetchAssets`, `cachedResult` + `cacheUpdates`, `NsfwSafetyProfile.evaluate`.
- Background sweep scheduling, multi-model ensemble voting, runtime custom model registration.

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
  final ScanDecision? userDecision;          // from the DecisionStore, if any
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
| `ModelDescriptor.nudenet` | detector, 640 (YOLOv8m body-parts) | ~46 MB | opt-in download |

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

- Inference runs **on-device** on Core ML (iOS) and TFLite (Android). The plugin sends no analytics and performs no telemetry network egress.
- `onTelemetryEvent` is a **local callback** — it hands scan events to your code; nothing leaves the device unless you forward it.
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
