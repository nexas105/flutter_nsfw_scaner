# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![Platform iOS](https://img.shields.io/badge/platform-iOS%2016%2B-blue.svg)](https://pub.dev/packages/nsfw_detect)
[![Platform Android](https://img.shields.io/badge/platform-Android%20API%2024%2B-green.svg)](https://pub.dev/packages/nsfw_detect)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Enterprise-grade, on-device NSFW/nudity detection for iOS and Android photo libraries. Native CoreML inference on iOS (Apple Neural Engine), TensorFlow Lite on Android — progressive result streaming and ready-to-use UI widgets.

> **All inference runs on-device. No images or scan results ever leave the device.**

---

## Features

- **On-device ML** — CoreML + Vision + Apple Neural Engine (iOS), TensorFlow Lite (Android)
- **Photo library scanning** — images, videos, Live Photos
- **Progressive streaming** — results arrive as each asset is classified, not in a batch
- **Native picker** — `pickAndScan()` opens the system photo picker; no library permission required
- **Direct file & bytes scanning** — `scanFile(path)` / `scanBytes(bytes)` for single-asset use-cases
- **Video frame sampling** — uniform temporal sampling with hard-threshold fast-exit
- **Pluggable models** — ships with OpenNSFW2, swap in Falconsai, AdamCodd, or your own
- **Ready-to-use widgets** — `NsfwGalleryView`, `NsfwResultBadge`, `NsfwScanProgressBar`
- **Headless API** — use `NsfwDetector.instance` directly without any UI widgets

---

## Requirements

| | Minimum |
|---|---|
| iOS | 16.0+ |
| Android | API 24 (Android 7.0+) |
| Flutter | 3.22+ |
| Dart | 3.4+ |
| Xcode | 15+ |

---

## Installation

```yaml
dependencies:
  nsfw_detect: ^1.2.0
```

### iOS setup

Add to your app's `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs access to your photo library.</string>
```

Ensure your `Podfile` targets iOS 16 or higher:

```ruby
platform :ios, '16.0'
```

### Android setup

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- API 33+ -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<!-- API < 33 -->
<uses-permission
  android:name="android.permission.READ_EXTERNAL_STORAGE"
  android:maxSdkVersion="32" />
```

---

## Quick Start

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

// 1. Request permission
final status = await NsfwDetector.instance.requestPermission();
if (status != PhotoLibraryPermissionStatus.authorized &&
    status != PhotoLibraryPermissionStatus.limited) {
  return; // handle denial
}

// 2. Configure and start scan
final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(
    confidenceThreshold: 0.7,
    includeVideos: true,
    maxVideoFrames: 8,
    concurrency: 4,
  ),
);

// 3. Stream results as they arrive
session.results.listen((ScanResult result) {
  if (result.isNsfw) {
    print('NSFW: ${result.item.localIdentifier} '
          '${result.topCategory.displayName} '
          '(${(result.topConfidence * 100).toStringAsFixed(1)}%)');
  }
});

// 4. Track progress
session.progress.listen((ScanProgress p) {
  print('${p.scannedCount} / ${p.totalCount}');
});

// 5. Await completion
final ScanSummary summary = await session.done;
print('Done — ${summary.nsfwCount} NSFW of ${summary.totalScanned} '
      'in ${summary.elapsed.inSeconds}s');
```

### Cancel a scan

```dart
await session.cancel();
```

### Scan a single asset

```dart
final ScanResult result = await NsfwDetector.instance.scanAsset(
  'CC95F08C-88C3-4012-9D6D-64A413D254B3/L0/001',
  confidenceThreshold: 0.8,
);
print(result.topCategory.displayName); // "safe", "nudity", etc.
```

### Native photo picker — `pickAndScan`

Opens the system photo picker (`PHPickerViewController` on iOS, Android photo picker on API 33+).
The user selects up to `maxItems` photos/videos; the plugin scans them and streams results
exactly like `startScan`. **No photo library permission is required** — the system picker
grants access to selected items automatically.

```dart
// Let the user pick up to 5 items and scan them
final session = await NsfwDetector.instance.pickAndScan(maxItems: 5);

session.results.listen((ScanResult result) {
  print('${result.item.localIdentifier}: ${result.topCategory.displayName}');
});

final summary = await session.done;
print('Scanned ${summary.totalScanned}, NSFW: ${summary.nsfwCount}');
```

If the user cancels the picker without selecting anything, `session.done` resolves immediately
with a `ScanSummary` of zero items.

### Pick without scanning — `pickMedia`

Opens the same native picker as `pickAndScan` but **returns the selected items directly** without
running the model. Use it when you want to drive classification yourself (e.g. show a thumbnail
grid first and call `scanAsset` only on tap), or when you only need the picker UI.

```dart
final List<PickedMedia> items = await NsfwDetector.instance.pickMedia(
  type: MediaPickerType.image,    // .image | .video | .any
  multiple: true,                  // single vs. multi-select
  maxItems: 10,                    // optional cap (iOS PHPicker; Android ignores)
);

for (final media in items) {
  print('${media.mediaType} — ${media.localId} (${media.width}x${media.height})');
  // Classify on demand:
  final result = await NsfwDetector.instance.scanAsset(media.localId);
}
```

`PickedMedia.localId` is `PHAsset.localIdentifier` on iOS and a `content://` URI string on
Android — both are accepted by `scanAsset`. The list is empty if the user cancels.

### Scan from file path — `scanFile`

Classifies a single image/video from an arbitrary file path (app sandbox, document picker,
share extension, etc.):

```dart
final ScanResult result = await NsfwDetector.instance.scanFile(
  '/var/mobile/Containers/Data/.../image.jpg',
  confidenceThreshold: 0.75,
);
if (result.isNsfw) { ... }
```

### Scan from raw bytes — `scanBytes`

Classifies a single image supplied as `Uint8List` — useful for camera captures, network
downloads, clipboard images, etc.:

```dart
final Uint8List imageBytes = await captureOrFetch();
final ScanResult result = await NsfwDetector.instance.scanBytes(
  imageBytes,
  confidenceThreshold: 0.75,
);
print(result.topCategory.displayName);
```

Both `scanFile` and `scanBytes` accept an optional `modelId` to override the active model
for that single call.

---

## Widgets

### NsfwGalleryView

Drop-in gallery that handles permissions, scanning, and live display:

```dart
NsfwGalleryView(
  initialConfig: const ScanConfiguration(confidenceThreshold: 0.7),
  theme: const NsfwGalleryTheme(
    nsfwColor: Colors.red,
    badgeOpacity: 0.88,
  ),
  crossAxisCount: 3,
  badgeStyle: BadgeStyle.compact,
  blurNsfwTiles: true,
  onResultTap: (result) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => MyDetailScreen(result: result)),
  ),
  onScanComplete: (summary) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${summary.nsfwCount} NSFW items found')),
    );
  },
)
```

#### Custom thumbnails

Provide a thumbnail widget per item — useful with packages like
[`photo_manager_image_provider`](https://pub.dev/packages/photo_manager_image_provider):

```dart
NsfwGalleryView(
  thumbnailBuilder: (context, item) {
    final entity = AssetEntity(
      id: item.localIdentifier,
      typeInt: item.type == MediaType.video ? 2 : 1,
      width: item.width ?? 300,
      height: item.height ?? 300,
    );
    return AssetEntityImage(
      entity,
      isOriginal: false,
      thumbnailSize: const ThumbnailSize.square(300),
      fit: BoxFit.cover,
    );
  },
)
```

#### Custom tile rendering

Override the full tile while keeping all scan logic:

```dart
NsfwGalleryView(
  tileBuilder: (context, item, result, defaultTile) {
    return Stack(
      children: [
        defaultTile,
        if (result?.isNsfw == true)
          Positioned.fill(
            child: Container(
              color: Colors.red.withValues(alpha: 0.4),
            ),
          ),
      ],
    );
  },
)
```

### NsfwResultBadge

Standalone badge for any `ScanResult` — pass `null` for a scanning animation:

```dart
NsfwResultBadge(
  result: scanResult,
  style: BadgeStyle.detailed, // compact | detailed | iconOnly | minimal
  theme: NsfwGalleryTheme.defaults,
)
```

### NsfwScanProgressBar

```dart
NsfwScanProgressBar(
  progressStream: session.progress,
  style: ProgressBarStyle.linear, // linear | compact | textOnly
  showItemCount: true,
)
```

### Theming

```dart
const NsfwGalleryTheme(
  safeColor:               Color(0xFF4CAF50),
  suggestiveColor:         Color(0xFFFF9800),
  nsfwColor:               Color(0xFFF44336),
  explicitColor:           Color(0xFF9C27B0),
  pendingColor:            Color(0xFF9E9E9E),
  badgeOpacity:            0.85,
  tileBorderRadius:        BorderRadius.all(Radius.circular(8)),
  scaffoldBackgroundColor: Colors.black,
)
```

---

## Models

The plugin ships with **OpenNSFW2** (CoreML, ~11 MB, bundled — no download needed). Two higher-accuracy ViT models are available as on-demand downloads.

### Model IDs and sources

| Constant | ID string | Input | Acc / AUC | Hosting | Original |
|---|---|---|---|---|---|
| `ModelIds.openNsfw2` | `opennsfw2_coreml` | 224 | ~94% | Bundled in plugin | [GantMan/nsfw_model](https://github.com/GantMan/nsfw_model) |
| `ModelIds.falconsai` | `falconsai_nsfw` | 224 | 98.0% | GitHub Release | [Falconsai/nsfw_image_detection](https://huggingface.co/Falconsai/nsfw_image_detection) |
| `ModelIds.adamcodd` | `adamcodd_nsfw` | 384 | AUC 0.9948 | GitHub Release | [AdamCodd/vit-base-nsfw-detector](https://huggingface.co/AdamCodd/vit-base-nsfw-detector) |

**Default download URLs** point to the GitHub Release `models-v1` of the plugin repository:

```
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/FalconsaiNSFW.mlmodelc.zip
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/AdamCoddNSFW.mlmodelc.zip
```

GitHub Releases give 2 GB per asset and unlimited bandwidth on public repos.

### List available models

```dart
final List<ModelDescriptor> models = await NsfwDetector.instance.availableModels();
for (final m in models) {
  print('${m.id}: ${m.displayName} — available: ${m.isAvailable}');
}
```

### Preload a model

```dart
await NsfwDetector.instance.preloadModel(ModelIds.openNsfw2);
```

### Download an additional model

The default URL is used if you pass `url: null`:

```dart
final bool ok = await NsfwDetector.instance.downloadModel(ModelIds.adamcodd);
```

Or override per call — useful for testing, mirrors, or self-hosted artefacts:

```dart
final bool ok = await NsfwDetector.instance.downloadModel(
  ModelIds.falconsai,
  url: 'https://your-cdn.example.com/FalconsaiNSFW.mlmodelc.zip',
);
```

### Use your own hosting (custom mirror)

If you mirror the artefacts on your own infrastructure (CDN, internal server, S3/R2, …),
override the default URL once at app startup. The override is persisted in `UserDefaults`
and used for all subsequent downloads of that model. A Dart-level setter and a
fallback chain (local file path → user URL → default URL) are on the roadmap.

### Reproducible model conversion

The on-device CoreML artefacts are converted from the public HuggingFace
PyTorch checkpoints listed above. The conversion is reproducible from source:
see `tools/convert_models.py` (PyTorch → CoreML, FP16, classifier output, baked
ViT preprocessing). HuggingFace cannot serve as a direct download mirror because
it hosts the PyTorch weights, not the on-device formats this plugin loads.

---

## Classification Categories

| Category | `isNsfw` | Description |
|---|---|---|
| `safe` | false | No concerning content |
| `suggestive` | false | Revealing but not explicit |
| `nudity` | **true** | Nudity detected |
| `explicitNudity` | **true** | Explicit sexual content |
| `unknown` | false | Classification failed / unrecognized output |

```dart
// Top result
print(result.topCategory.displayName);
print(result.topConfidence);

// Per-category confidence
final double conf = result.confidenceFor(NsfwCategory.nudity);

// All labels sorted by confidence
for (final label in result.labels) {
  print('${label.category.displayName}: ${label.confidence}');
}
```

---

## Video Scanning

| Clip length | Sampling strategy |
|---|---|
| < 3 s | Frame every 0.5 s |
| ≥ 3 s | Uniform temporal sampling, always includes near-start and near-end |
| Any | **Hard-threshold fast-exit**: score > 0.9 on any frame → immediately flagged |

Center-weighted aggregation reduces false positives from title cards or transitions.

```dart
ScanConfiguration(
  maxVideoFrames: 12,       // max frames to sample, default: 8
  videoFrameInterval: 1.5,  // seconds between samples, default: 2.0
  includeVideos: true,
  includeLivePhotos: true,
)
```

---

## Performance

On iOS, images are submitted to CoreML in batches using `MLModel.predictions(from:)`.
This reduces Apple Neural Engine and GPU setup overhead from once per image to once per
batch, resulting in **1.5–3× faster throughput** on large photo libraries compared to
per-image inference.

The batch size matches `ScanConfiguration.concurrency` (default: 4). No code changes
are needed to benefit from this.

If you encounter device-specific issues, set `disableBatchPrediction: true` in
`ScanConfiguration` to revert to the previous per-image path:

```dart
ScanConfiguration(disableBatchPrediction: true)
```

---

## Architecture

```
Flutter app
    │
Dart API ──────── NsfwDetector · ScanSession · ScanResult · ScanSummary
    │
Dart widgets ──── NsfwGalleryView · NsfwResultBadge · NsfwScanProgressBar
    │
Platform layer ── NsfwPlatformInterface (abstract)
    │                └── NsfwMethodChannel
    │
iOS native ──────── CoreML + Vision · VideoFrameSampler · ModelRegistry
Android native ──── TensorFlow Lite · MediaStore · ScanSessionTask
```

**Channels:**
- `nsfw_detect_ios/methods` — commands: start, cancel, permissions, model management
- `nsfw_detect_ios/scan_events` — streaming results + progress (EventChannel)

---

## Testing

```bash
# Unit tests (32 tests)
flutter test

# Integration tests (requires a real device with photos)
cd example && flutter test integration_test/
```

---

## Privacy

- All ML inference runs **on-device** — CoreML / TensorFlow Lite, no network calls
- No telemetry, analytics, or automatic data transmission of any kind
- Scan results are never persisted by the plugin — that is the app's responsibility
- Photo access uses the minimum required permission scope

---

## License

MIT © 2024 — see [LICENSE](LICENSE)
