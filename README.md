# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![pub points](https://img.shields.io/pub/points/nsfw_detect)](https://pub.dev/packages/nsfw_detect/score)
[![likes](https://img.shields.io/pub/likes/nsfw_detect)](https://pub.dev/packages/nsfw_detect)
[![platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20Web-blue)](https://pub.dev/packages/nsfw_detect)
[![license](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Privacy-friendly NSFW detection for Flutter. Inference runs **on-device** — no telemetry, no media uploads.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

// Images, videos, GIFs — same call, same result shape.
final result = await NsfwDetector.instance.scanFile('/path/to/file.jpg');
if (result.isNsfw) {
  // Blur, block, or route to review — your choice.
}
```

That's the whole API for the common case: no init, no permission for files on disk. Add more entry points as you need them.

> Detection is probabilistic. Treat it as one local moderation signal inside a broader safety workflow.

---

## Contents

- [Install](#install)
- [Platform setup](#platform-setup) — **required for any media API**
- [What you can scan](#what-you-can-scan)
- [Usage](#usage)
- [Web](#web)
- [Result shape](#result-shape)
- [Models](#models)
- [Permissions](#permissions)
- [Privacy & limitations](#privacy--limitations)
- [Documentation](#documentation)
- [Example app](#example-app)

---

## Install

```yaml
dependencies:
  nsfw_detect: ^2.8.0
```

```bash
flutter pub get
```

| Platform | Minimum |
| --- | --- |
| iOS | 15.0+ (Xcode 15+) |
| Android | API 24 / Android 7.0+ |
| Web | one-shot APIs only — see [Web](#web) |
| Flutter / Dart | 3.22+ / 3.4+ |

---

## Platform setup

**Any API that touches media needs the matching usage strings / permissions in your host app.** On iOS a missing key terminates the process with `SIGABRT` the instant the system reads it — there is no graceful runtime error. This is the most common integration issue, so set it up before your first scan.

This applies to `pickAndScan`, `pickMedia`, `scanAsset`, `startScan`, and `startCameraScan`. The picker APIs are **not** exempt: `PHPickerViewController` grants per-item access without a prompt, but the plugin still resolves `PHAsset` identifiers behind the scenes, and iOS gates that on `NSPhotoLibraryUsageDescription`.

### iOS — `ios/Runner/Info.plist`

```xml
<!-- pickAndScan / pickMedia / scanAsset / startScan -->
<key>NSPhotoLibraryUsageDescription</key>
<string>We scan selected media on-device to flag NSFW content.</string>

<!-- startCameraScan -->
<key>NSCameraUsageDescription</key>
<string>We analyze camera frames on-device to flag NSFW content.</string>

<!-- Only if you record video with audio for analysis -->
<key>NSMicrophoneUsageDescription</key>
<string>Used when recording video with audio for moderation.</string>
```

### Android — `android/app/src/main/AndroidManifest.xml`

```xml
<!-- API 33+ — pickAndScan / scanAsset / startScan for images & videos -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>

<!-- API ≤ 32 fallback -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32"/>

<!-- startCameraScan -->
<uses-permission android:name="android.permission.CAMERA"/>
```

### Preflight at startup (recommended)

`checkPlatformSetup()` reports which keys are missing **before** you hit a media API. It reads `Info.plist` (iOS) / `PackageInfo.requestedPermissions` (Android) only — it never triggers the OS permission layer, so it is safe to call at launch:

```dart
final setup = await NsfwDetector.instance.checkPlatformSetup();
if (!setup.isComplete) {
  debugPrint('nsfw_detect: missing platform keys → ${setup.missingKeys}');
  // e.g. ['NSPhotoLibraryUsageDescription'] — route the user to your setup UI.
}
```

When a key is missing, the affected native APIs return `FlutterError(code: "MISSING_USAGE_DESCRIPTION", …)` instead of crashing the host. Catch it on the Dart side and guide the user.

If a test app crashes on the first scan, grep the iOS log for `NSPhotoLibraryUsageDescription` — that's a missing Info.plist key, not a plugin bug. Add it, then `flutter clean && flutter run`.

---

## What you can scan

| Source | API | Permission |
| --- | --- | --- |
| Image file on disk | `scanFile` · `isNsfwFile` | none |
| Video file on disk (mp4, mov, …) | `scanFile` · `isNsfwFile` | none |
| Animated image (gif, apng, webp) | `scanFile` | none |
| Bytes in memory | `scanBytes` · `isNsfwBytes` | none |
| Flutter `ImageProvider` | `scanImageProvider` | none |
| Remote URL (image or video) | `scanUrl` | none (network) |
| Photo-library asset (image or video) | `scanAsset` · `isNsfwAsset` | photo library |
| System picker (image or video) | `pickMedia` · `pickAndScan` | photo library — see [setup](#platform-setup) |
| Whole library (photos + videos) | `startScan` | photo library |
| Live camera | `startCameraScan` | camera |
| Export a library original (image or video) | `exportAsset(id)` → temp file path | photo library |
| Mixed batch | `scanPaths(['file://…', 'https://…', '/abs/path', 'asset-id'])` | per-source |

**Videos are first-class.** `scanFile` auto-detects the container and samples frames at a configurable interval — no separate API or model needed. Each headless API returns a `ScanResult` (full label list + detections); the `isNsfw*` variants return a `Future<bool>` shortcut.

**Moving library hits elsewhere.** `exportAsset(localIdentifier)` writes the asset's full-quality bytes — photo *or* video, native container, no re-encode (HEIC/JPEG/PNG/MOV/MP4 …) — to a temp file and returns its path (`null` if the asset is gone or iCloud-only and offline). You own the file: copy/encrypt it, then delete it. Combine with `deleteAssets` to move a hit out of the library.

---

## Usage

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

`pickMedia` returns the picked items without scanning — the other half of the same API.

### Scan a URL before showing it

```dart
final r = await NsfwDetector.instance.scanUrl(
  Uri.parse('https://cdn.example.com/avatar.jpg'),
  timeout: const Duration(seconds: 8),
);
if (r.isNsfw) { /* hide / report */ }
```

Hard-capped at 32 MB by default to keep a malicious server from OOM-ing you; override via `maxBytes`.

### Scan a video file

```dart
final result = await NsfwDetector.instance.scanFile(
  '/path/to/clip.mp4',
  configuration: const ScanConfiguration(
    maxVideoFrames: 12,       // default 8 — more frames, more accurate
    videoFrameInterval: 1.0,  // default 2.0 s — sample every second
  ),
);
```

The same call works for `.mov`, `.gif`, `.apng`, and `.webp`. The plugin samples frames automatically and aggregates them into one `ScanResult`.

### Whole-library scan with progress

```dart
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  const ScanConfiguration.strict(includeVideos: true),
);
if (session == null) return; // User denied — show your permission UI.

session.results.listen((r) { if (r.isNsfw) { /* … */ } });
session.progress.listen((p) => print('${p.scannedCount}/${p.totalCount}'));
final summary = await session.done;
```

Presets: `.strict()` (threshold 0.85), `.moderate()` (0.7), `.permissive()` (0.5), `.fastScan()` (concurrency 8). `includeVideos` defaults to `true`.

### Pre-warm models on splash

```dart
await NsfwDetector.instance.init(const NsfwInitOptions(
  preloadModels: [
    ModelIds.openNsfw2,        // fast default classifier (~11 MB)
    ModelIds.falconsai,        // ViT classifier (~152 MB)
    ModelIds.adamcodd,         // ViT classifier, 384px (~152 MB)
    ModelDescriptor.nudenet,   // body-part detector (~46 MB)
  ],
  downloadIfMissing: [
    ModelIds.falconsai,
    ModelIds.adamcodd,
    ModelDescriptor.nudenet,
  ],
));
```

Skipping `init` is fine — the plugin lazy-loads on first use. `NsfwInitOptions.lazy()` / `.debug()` / `.production()` cover the typical shapes.

### Higher accuracy via ensemble

```dart
final config = ScanConfiguration.strict().copyWith(
  ensemble: MajorityEnsemble(
    modelIds: [ModelIds.openNsfw2, ModelIds.falconsai, ModelIds.adamcodd],
  ),
);
final result = await NsfwDetector.instance.scanFile(path, configuration: config);
```

`MajorityEnsemble` runs all three classifiers and takes the consensus; borderline scores (~0.45–0.55) abstain so a single uncertain model can't flip the verdict. `WeightedEnsemble` averages per-category confidences with configurable weights. Cost scales linearly with model count — preload them so the first scan is warm.

### Detect, then classify each region

```dart
final r = await NsfwDetector.instance.scanFileDetectThenClassify(
  '/path/to/image.jpg',
  detectorModelId: ModelDescriptor.nudenet,
);
// r.detections[i].labels — per-region NSFW classification.
```

Stronger than detector-only (graded confidence per region) or classifier-only (per-region attribution).

### Redact detector boxes in place

```dart
final redacted = await NsfwDetector.instance.redactBytes(
  bytes,
  result,
  mode: RedactionMode.blur, // or .pixelate, .blackBox
  intensity: 0.8,
);
```

With non-empty `result.detections`, only the per-detection boxes are redacted; otherwise it falls back to whole-image redaction.

### Find perceptual duplicates

```dart
final clusters = await NsfwDetector.instance.findDuplicates(
  items, // List<MediaItem>
  loadBytes: (id) async => await myStorage.read(id),
);
// clusters: List<List<MediaItem>> — each cluster ≥ 2 visually-identical items.
```

dHash + LRU cache; `loadBytes` decouples the detector from your storage layer.

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
// Later scans of that asset come back with userDecision applied:
// .allow forces isNsfw=false, .block forces isNsfw=true.
```

`InMemoryDecisionStore` is the dependency-free default; `SharedPreferencesDecisionStore` persists across cold starts.

### Drop-in permissions UI

```dart
NsfwPermissionsView(
  kinds: const [PermissionKind.photoLibrary, PermissionKind.camera],
  onOpenSettings: () => /* host opens system Settings */,
)
```

The plugin pulls in neither `permission_handler` nor `app_settings`; wire `onOpenSettings` to your preferred deep-link package.

### Telemetry hooks

```dart
NsfwDetector.instance.onTelemetryEvent = (e) => myAnalytics.log(e);
```

Structured `scanCompleted` / `modelLoaded` / `downloadFinished` / … events with timing and a PII-free confidence decile. `localId` only attaches when `includeLocalIdsInTelemetry` is set. The plugin sends nothing — this is a local callback.

### Localize plugin strings

```dart
NsfwLocalizations.current = const NsfwLocalizationsDe();
```

Bundled EN/DE/ES/FR/JA cover category names, permission hints, confidence buckets, and widget button labels. `NsfwLocalizations.resolve('es-MX')` picks a bundle by BCP-47 tag.

---

## Web

The `web` platform runs the **one-shot** scan APIs in the browser — `scanBytes`, `scanFile` (a `blob:`/`http(s):` URL), `pickMedia`, and detection-mode scans. Classification runs on [nsfwjs](https://github.com/infinitered/nsfwjs) (TensorFlow.js); detection on [NudeNet](https://github.com/notAI-tech/NudeNet) via onnxruntime-web. The JS runtimes load on demand from a CDN — no `index.html` edits required.

```dart
// Detection-mode scans need a NudeNet model — point this at a
// CORS-reachable .onnx URL once, before the first scan.
NsfwWebConfig.nudeNetModelUrl = 'https://your-host.example/nudenet_320n.onnx';

final result = await NsfwDetector.instance.scanBytes(bytes);
```

**Not available on web:** photo-library scanning (`startScan`), camera scanning, and background sweep — they have no browser equivalent and throw `UnimplementedError`. nsfwjs has no dedicated nudity class, so the web classifier reports `explicitNudity` rather than `nudity`, and its confidence scores are not numerically comparable to the native OpenNSFW2 classifier.

---

## Result shape

```dart
class ScanResult {
  final MediaItem item;
  final ScanStatus status;       // completed | failed | skipped
  final DateTime scannedAt;
  final List<NsfwLabel> labels;  // NSFW labels first, then by confidence
  final List<BodyPartDetection> detections; // detector-mode only
  final ScanDecision? userDecision;          // from the DecisionStore, if any
  // convenience getters: isNsfw, topCategory, topConfidence, hasNudity,
  //   hasExplicitContent, isSuggestive, hasDetections, confidenceDescription
}
```

| Category | `isNsfw` | Typical handling |
| --- | --- | --- |
| `safe` | false | allow |
| `suggestive` | false | optional warning |
| `nudity` | true | block or blur |
| `explicitNudity` | true | block / route to review |
| `unknown` | false | apply your fallback policy |

`result.isNsfw` is true **only** when the scan completed, the top category is NSFW, and confidence ≥ the threshold. `toJson()` / `fromJson(...)` preserve the threshold so `isNsfw` is stable across persistence.

---

## Models

Four models ship out of the box — preload one for the lightest footprint, or several to ensemble for higher accuracy. None is bundled in the binary; each downloads on first use (or eagerly via `NsfwInitOptions.downloadIfMissing`).

| Id | Shape | Size | Strength |
| --- | --- | --- | --- |
| `ModelIds.openNsfw2` | classifier, 224 (CNN) | ~11 MB | default — small, fast, good baseline |
| `ModelIds.falconsai` | classifier, 224 (ViT) | ~152 MB | different errors than openNsfw2 — great ensemble partner |
| `ModelIds.adamcodd` | classifier, 384 (ViT) | ~152 MB | higher-resolution ViT — best single-model accuracy |
| `ModelDescriptor.nudenet` | detector, 640 (YOLOv8m) | ~46 MB | spatial — per-region boxes, drives redaction + detect-then-classify |

Pick a single classifier via `ScanConfiguration.modelId`, or combine several via `ScanConfiguration.ensemble`. Set a custom mirror with `setModelUrl(modelId, url)`; the archive's SHA-256 is verified before extraction when pinned on the descriptor. Manage downloads / preloads via `NsfwDetector.instance.models` (`NsfwModelManager`).

---

## Permissions

| Workflow | iOS | Android |
| --- | --- | --- |
| `scanFile` · `scanBytes` · `scanUrl` · `scanImageProvider` | none | none |
| `pickMedia` · `pickAndScan` | `NSPhotoLibraryUsageDescription` | none |
| `scanAsset` · `startScan` | `NSPhotoLibraryUsageDescription` | `READ_MEDIA_IMAGES` + `READ_MEDIA_VIDEO` (API 33+) / `READ_EXTERNAL_STORAGE` (≤ 32) |
| `startCameraScan` | `NSCameraUsageDescription` | `CAMERA` |

The picker APIs need `NSPhotoLibraryUsageDescription` on iOS even though `PHPickerViewController` grants per-item access without a prompt — the plugin reads the `PHAsset` to pull bytes, and iOS gates that path on the key. See [Platform setup](#platform-setup) for the snippets.

The plugin requests at runtime via `requestPermission` / `requestCameraPermission`. `NsfwPermissionsView` is a drop-in panel showing live status with a Request button.

---

## Privacy & limitations

- Inference runs **on-device** on Core ML (iOS) and TFLite (Android). The plugin performs no analytics and no telemetry network egress.
- `onTelemetryEvent` is a **local callback** — nothing leaves the device unless you forward it.
- Picker-based scanning avoids full photo-library permission via per-item access.
- `scanUrl` is the only Dart-initiated network egress; everything else is local. Model downloads are explicit calls or the `NsfwInitOptions.downloadIfMissing` path you opt into.

NSFW detection is probabilistic — expect false positives and negatives on unusual lighting, partial visibility, illustrations, screenshots, low-resolution media, compressed video, or ambiguous content. Tune `confidenceThreshold` for your product risk, and for sensitive workflows combine on-device detection with user reporting, human review, and policy-specific rules.

Your app remains responsible for explaining permissions, handling results, storing moderation state, and complying with platform / privacy / safety requirements.

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

Full API reference on [pub.dev](https://pub.dev/documentation/nsfw_detect/latest/). Release history in [CHANGELOG.md](CHANGELOG.md).

---

## Example app

```bash
git clone https://github.com/nexas105/flutter_nsfw_scaner.git
cd flutter_nsfw_scaner/example
flutter pub get
flutter run
```

Use a real device for photo-library and camera workflows — the iOS simulator has no camera and emulator libraries are usually empty. The example covers the gallery view, picker flow, camera scanner, result detail, moderation gate, and model selection.

---

## Links

- [pub.dev package](https://pub.dev/packages/nsfw_detect)
- [API documentation](https://pub.dev/documentation/nsfw_detect/latest/)
- [GitHub repository](https://github.com/nexas105/flutter_nsfw_scaner)
- [Issue tracker](https://github.com/nexas105/flutter_nsfw_scaner/issues)
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
