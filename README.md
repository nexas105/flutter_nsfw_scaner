# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![Platform iOS](https://img.shields.io/badge/platform-iOS%2016%2B-blue.svg)](https://pub.dev/packages/nsfw_detect)
[![Platform Android](https://img.shields.io/badge/platform-Android%20API%2024%2B-green.svg)](https://pub.dev/packages/nsfw_detect)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Enterprise-grade, on-device NSFW/nudity detection for iOS and Android photo libraries. Native CoreML inference on iOS (Apple Neural Engine), TensorFlow Lite on Android — progressive result streaming and ready-to-use UI widgets.

> **All inference runs on-device. No images or scan results ever leave the device.**

---

## Quick Install & Run the Demo / Schnellstart & Demo

<details>
<summary><b>🇬🇧 English — Quick Install & Demo App</b></summary>

### Prerequisites

1. **Install Flutter** (if not already installed):
   ```bash
   # macOS (via Homebrew)
   brew install --cask flutter

   # Or follow the official guide: https://docs.flutter.dev/get-started/install
   ```

2. **Verify your setup:**
   ```bash
   flutter doctor
   ```
   Make sure there are no critical (`✗`) issues. iOS development requires Xcode, Android development requires Android Studio / SDK.

### Run the Demo App

```bash
# 1. Clone the repository
git clone https://github.com/nexas105/flutter_nsfw_scaner.git
cd flutter_nsfw_scaner/example

# 2. Fetch dependencies
flutter pub get

# 3. Run on a connected device or simulator
flutter run
```

That's it — the demo app will launch on your device/simulator. Use the in-app settings to switch between classification and detection mode, change models, or clear the scan cache.

</details>

<details>
<summary><b>🇩🇪 Deutsch — Schnellstart & Demo-App</b></summary>

### Voraussetzungen

1. **Flutter installieren** (falls noch nicht geschehen):
   ```bash
   # macOS (via Homebrew)
   brew install --cask flutter

   # Oder der offiziellen Anleitung folgen: https://docs.flutter.dev/get-started/install
   ```

2. **Setup überprüfen:**
   ```bash
   flutter doctor
   ```
   Stelle sicher, dass es keine kritischen (`✗`) Probleme gibt. Für iOS-Entwicklung brauchst du Xcode, für Android Android Studio / SDK.

### Demo-App starten

```bash
# 1. Repository clonen
git clone https://github.com/nexas105/flutter_nsfw_scaner.git
cd flutter_nsfw_scaner/example

# 2. Dependencies herunterladen
flutter pub get

# 3. Auf einem angeschlossenen Gerät oder Simulator starten
flutter run
```

Das war's — die Demo-App startet auf deinem Gerät/Simulator. Über die Einstellungen in der App kannst du zwischen Klassifizierungs- und Erkennungsmodus wechseln, Modelle ändern oder den Scan-Cache leeren.

</details>

---

## Features

- **On-device ML** — CoreML + Vision + Apple Neural Engine (iOS), TensorFlow Lite (Android). No network calls, no telemetry.
- **Two scan modes** — **classification** (per-asset NSFW probabilities, OpenNSFW2 / Falconsai / AdamCodd) and **detection** (per-asset bounding boxes for 18 body-part classes, NudeNet YOLOv8m).
- **Photo library scanning** — images, videos, Live Photos. Incremental cache so re-scans of an unchanged 200k-asset library complete in seconds.
- **Live camera scan** *(2.1.0)* — `NsfwCameraView` widget + `startCameraScan()` API for AVCaptureSession (iOS) / CameraX (Android) feeds, configurable FPS, classification + detection mode, optional blur-on-NSFW overlay.
- **Progressive streaming** — results arrive as each asset is classified, not in a batch. Cached items replay with `result.fromCache = true`.
- **Native picker** — `pickAndScan()` and `pickMedia()` open the system photo picker; no library permission required.
- **Direct file & bytes scanning** — `scanFile(path)` / `scanBytes(bytes)` for single-asset use-cases.
- **Video frame sampling** — uniform temporal sampling with hard-threshold fast-exit.
- **Pluggable models** — ships with OpenNSFW2, swap in Falconsai, AdamCodd, or NudeNet — all hosted on the plugin's GitHub Release (`models-v1`).
- **Controller-based state** — `NsfwScanController` (`ChangeNotifier`) holds permission, session, items, results and progress; bind multiple views to the same controller, or let `NsfwGalleryView` own one internally.
- **Ready-to-use widgets** — `NsfwGalleryView`, `NsfwCameraView`, `NsfwResultBadge`, `NsfwScanProgressBar`, `NsfwDetectionOverlay`, `NsfwPermissionsView` *(2.1.0)*.
- **Headless API** — use `NsfwDetector.instance` directly without any UI widgets.

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
  nsfw_detect: ^2.0.0
```

> **Migrating from 1.x?** The two breaking changes are: `PickedMedia.mediaType` is now a `MediaType` enum (was `String`) and `NsfwGalleryView` accepts an optional `controller` parameter. See [CHANGELOG](CHANGELOG.md#200) for the full diff.

### iOS setup

Add to your app's `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>This app needs access to your photo library.</string>

<!-- Required only if you use NsfwCameraView / startCameraScan (2.1.0) -->
<key>NSCameraUsageDescription</key>
<string>This app uses the camera for live NSFW detection.</string>
```

> Without `NSCameraUsageDescription`, iOS terminates the app the moment `AVCaptureDevice.requestAccess(for: .video)` is called. The string is shown in the system permission dialog — make it user-facing.

Ensure your `Podfile` targets iOS 16 or higher:

```ruby
platform :ios, '16.0'
```

### Android setup

Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Photo library — API 33+ -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<!-- Photo library — API < 33 -->
<uses-permission
  android:name="android.permission.READ_EXTERNAL_STORAGE"
  android:maxSdkVersion="32" />

<!-- Camera (2.1.0) — required only if you use NsfwCameraView / startCameraScan -->
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="false"/>
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false"/>
```

> Marking the camera features `required="false"` prevents the Play Store from filtering your listing on devices without a camera; switch to `required="true"` if a camera is mandatory for your app.

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
  // 2.0.0: media.mediaType is a MediaType enum (was a String).
  if (media.mediaType == MediaType.video) {
    print('video clip — ${media.localId} (${media.durationMs} ms)');
  } else {
    print('image — ${media.localId} (${media.width}x${media.height})');
  }
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

## Detection mode — body-part bounding boxes

Switch to `ScanMode.detection` to run NudeNet (YOLOv8m) instead of a binary classifier.
Each result then carries per-asset bounding boxes for 18 body-part classes (`FEMALE_BREAST_EXPOSED`,
`FEMALE_GENITALIA_COVERED`, `BUTTOCKS_EXPOSED`, …) on top of the existing aggregated
`labels` / `topCategory` / `isNsfw` fields, so all your existing classification code keeps
working.

```dart
final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(
    modelId: ModelIds.nudenet,
    mode: ScanMode.detection,
    detectionConfidenceThreshold: 0.25,  // NudeNet per-box confidence
    iouThreshold: 0.45,                   // NMS IoU
    confidenceThreshold: 0.7,             // gallery / isNsfw threshold
  ),
);

session.results.listen((ScanResult result) {
  for (final box in result.detections ?? []) {
    print('${box.label} @ ${(box.confidence * 100).toStringAsFixed(0)}% '
          '[${box.aggregatedCategory}] '
          '(${box.x.toStringAsFixed(2)}, ${box.y.toStringAsFixed(2)} '
          '${box.width.toStringAsFixed(2)}x${box.height.toStringAsFixed(2)})');
  }
});
```

Coordinates are normalised `[0, 1]` with origin top-left. The `aggregatedCategory` field maps
each raw NudeNet label onto the canonical `safe / suggestive / nudity / explicitNudity`
buckets (e.g. `FEMALE_BREAST_EXPOSED → nudity`, `FEMALE_GENITALIA_EXPOSED → explicitNudity`).

**Authoritative-NSFW behaviour:** any surviving `*_EXPOSED` detection (genitalia, anus, breast,
buttocks) boosts the aggregated `nudity` / `explicitNudity` confidence to `1.0`, so a single
exposed-body-part hit always flips `result.isNsfw` to `true` and triggers downstream gallery
filters and the post-scan upload — regardless of NudeNet's own per-box score. Per-box scores
remain available on each `BodyPartDetection` for UI rendering.

The model is downloaded on first use (~46 MB compressed). To pre-warm it before the first scan:

```dart
await NsfwDetector.instance.preloadModel(ModelIds.nudenet);
```

---

## Live camera scan *(2.1.0)*

Run the same on-device classifier or NudeNet detector against the live camera feed instead of the photo library. Native AVCaptureSession on iOS, CameraX on Android.

### Drop-in widget — `NsfwCameraView`

The widget owns its own `CameraScanSession` and a native preview (PlatformView). Optional HUD overlay (category label + confidence bar + NSFW badge) and optional blur-on-NSFW.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

NsfwCameraView(
  config: const CameraConfiguration(
    fps: 2,                              // 1–30, default 2
    mode: ScanMode.classification,       // or ScanMode.detection for boxes
    resolution: CameraResolution.medium,
    confidenceThreshold: 0.7,
  ),
  showHudOverlay: true,
  enableBlurOnNsfw: true,                // BackdropFilter blur fades in/out
  blurSigma: 12.0,
  onResult: (CameraFrameResult r) {
    if (r.isNsfw) {
      // r.frameTimestamp / r.topCategory / r.topConfidence / r.detections
    }
  },
  onPermissionDenied: () {
    // Surface NsfwPermissionsView, see below.
  },
);
```

### Headless API — `startCameraScan` / `stopCameraScan`

When you want to drive the camera yourself (e.g. mix with another preview source, or run without UI), use the session API directly.

```dart
final CameraScanSession session = await NsfwDetector.instance.startCameraScan(
  const CameraConfiguration(fps: 4, mode: ScanMode.detection),
);

session.results.listen(
  (CameraFrameResult r) {
    print('${r.frameTimestamp.toIso8601String()} '
          '${r.topCategory.displayName} ${r.topConfidence}');
    if (r.detections != null) {
      for (final box in r.detections!) {
        print('  ${box.className} @ ${box.box}');
      }
    }
  },
  onError: (e) {
    if (e is CameraPermissionDeniedException) { /* prompt user */ }
    if (e is CameraErrorException) { /* surface message */ }
  },
);

// Later:
await NsfwDetector.instance.stopCameraScan();
```

Only one camera session is allowed at a time — `startCameraScan` throws a `StateError` if you call it while another session is running. Errors arrive on `session.results` as stream errors (typed `CameraPermissionDeniedException` / `CameraErrorException`), not as null results.

### Detection mode on the live feed

Set `mode: ScanMode.detection` and the per-frame `CameraFrameResult.detections` carries NudeNet bounding boxes — paint them on top of the preview using the existing `NsfwDetectionOverlay`:

```dart
Stack(
  children: [
    NsfwCameraView(
      config: const CameraConfiguration(mode: ScanMode.detection, fps: 4),
      onResult: (r) => setState(() => _last = r),
      showHudOverlay: false,
    ),
    if (_last?.detections != null)
      Positioned.fill(
        child: NsfwDetectionOverlay(detections: _last!.detections!),
      ),
  ],
);
```

### Camera permissions

`NsfwCameraView` does not request camera permission for you (so it works even when you've already prompted via your own flow). Use `NsfwPermissionsView` (below) or `NsfwDetector.instance.requestCameraPermission()` directly.

> **Don't forget the manifests.** Add `NSCameraUsageDescription` to `Info.plist` and `<uses-permission android:name="android.permission.CAMERA"/>` to `AndroidManifest.xml` — see [Installation](#installation).

---

## Permissions UI — `NsfwPermissionsView` *(2.1.0)*

Reusable widget that surfaces every permission the plugin needs (photo library + camera) with the current status, an explainer, and a Request / Open Settings button. Auto-refreshes when the app returns from system Settings.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:app_settings/app_settings.dart'; // host-app dep, not bundled

NsfwPermissionsView(
  // theme: optional NsfwTheme; defaults to NsfwTheme.defaults()
  onOpenSettings: AppSettings.openAppSettings,
  onPermissionChanged: (PermissionKind kind, PermissionStatus status) {
    debugPrint('${kind.defaultLabel}: ${status.name}');
  },
  // Optional: filter to specific permissions
  // kinds: const [PermissionKind.camera],
);
```

Behaviour:

- `authorized` / `limited` → ✓ icon, no button.
- `notDetermined` / `denied` → "Request" button calls `requestPermission()` / `requestCameraPermission()` and updates the row.
- `permanentlyDenied` / `restricted` → "Open Settings" button calls `onOpenSettings`. If the callback is `null`, no button is rendered (lets you hide the row when you don't want a deep-link).
- The widget is plugin-side dependency-free — the deep-link to system Settings is delegated to the host app (typically via `app_settings`). This keeps the plugin lean.

If you want to drive permissions yourself instead:

```dart
final photoStatus = await NsfwDetector.instance.checkPermission();
final cameraStatus = await NsfwDetector.instance.checkCameraPermission();

if (cameraStatus.canRequest) {
  await NsfwDetector.instance.requestCameraPermission();
}
```

---

## Controller-based state — `NsfwScanController`

Hosts can hold the scan state explicitly via `NsfwScanController` (a `ChangeNotifier`).
Multiple views can bind to the same controller, the AppBar can rebuild on result count
changes without `setState`, and the controller survives the host widget's lifecycle
when wrapped in an `InheritedNotifier`.

```dart
late final NsfwScanController _controller;

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  _controller ??= NsfwScanController(
    initialConfig: const ScanConfiguration(),
  );
}

@override
void dispose() {
  _controller.dispose();
  super.dispose();
}

@override
Widget build(BuildContext context) {
  return NsfwGalleryView(
    controller: _controller,           // ← optional; widget owns one if null
    onResultTap: (r) { ... },
  );
}
```

Without the parameter, `NsfwGalleryView` builds its own controller internally — drop-in
behaviour identical to 1.x.

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

The plugin ships with **OpenNSFW2** (CoreML, ~11 MB, bundled — no download needed). Three higher-accuracy models are available as on-demand downloads from the plugin's GitHub Release `models-v1`.

### Model IDs and sources

| Constant | ID string | Kind | Input | Acc / AUC | Size (zip) | Original |
|---|---|---|---|---|---|---|
| `ModelIds.openNsfw2` | `opennsfw2_coreml` | classifier | 224 | ~94% | bundled (~11 MB) | [GantMan/nsfw_model](https://github.com/GantMan/nsfw_model) |
| `ModelIds.falconsai` | `falconsai_nsfw` | classifier | 224 | 98.0% | ~75 MB | [Falconsai/nsfw_image_detection](https://huggingface.co/Falconsai/nsfw_image_detection) |
| `ModelIds.adamcodd` | `adamcodd_nsfw` | classifier | 384 | AUC 0.9948 | ~78 MB | [AdamCodd/vit-base-nsfw-detector](https://huggingface.co/AdamCodd/vit-base-nsfw-detector) |
| `ModelIds.nudenet` | `nudenet` | **detector** | 640 | YOLOv8m, 18 classes | ~46 MB | [notAI-tech/NudeNet](https://github.com/notAI-tech/NudeNet) |

**Default download URLs** all live on the same GitHub Release tag `models-v1`:

```
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/FalconsaiNSFW.mlmodelc.zip   (iOS, ~158 MB FP16)
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/FalconsaiNSFW.tflite.zip    (Android, ~75 MB INT8 weight-only)
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/AdamCoddNSFW.mlmodelc.zip   (iOS)
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/AdamCoddNSFW.tflite.zip     (Android)
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/NudeNetDetector.mlmodelc.zip (iOS)
https://github.com/nexas105/flutter_nsfw_scaner/releases/download/models-v1/NudeNetDetector.tflite.zip   (Android)
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
