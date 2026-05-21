# nsfw_detect

[![pub package](https://img.shields.io/pub/v/nsfw_detect.svg)](https://pub.dev/packages/nsfw_detect)
[![pub points](https://img.shields.io/pub/points/nsfw_detect)](https://pub.dev/packages/nsfw_detect/score)
[![likes](https://img.shields.io/pub/likes/nsfw_detect)](https://pub.dev/packages/nsfw_detect)
[![platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android-blue)](https://pub.dev/packages/nsfw_detect)
[![license](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

Privacy-friendly NSFW detection for Flutter apps, running fully on-device.

Use `nsfw_detect` to scan images, videos, selected media, photo libraries, and camera frames locally with Core ML on iOS and TensorFlow Lite on Android.

> Detection is probabilistic. Use it as a local moderation signal and one layer in a broader safety workflow.

## Features

- On-device NSFW detection for Flutter apps
- Image, video, photo library, native picker, file, bytes, and camera scanning
- iOS support via Core ML and Vision
- Android support via TensorFlow Lite
- Stream-based scan results and progress updates
- Configurable confidence thresholds and model selection
- Classification categories: safe, suggestive, nudity, explicit nudity, unknown
- Optional detection mode with body-part bounding boxes
- Incremental scan cache for large media libraries
- Ready-to-use widgets and headless Dart APIs
- No telemetry or automatic media transmission by the plugin

## Installation

```yaml
dependencies:
  nsfw_detect: ^2.1.1
```

Then run:

```bash
flutter pub get
```

## Platform requirements

| Platform | Minimum |
| --- | --- |
| iOS | 16.0+ |
| Android | API 24 / Android 7.0+ |
| Flutter | 3.22+ |
| Dart | 3.4+ |
| Xcode | 15+ |

## Quickstart

### 0. Optional one-time init

Wrap your app's bootstrap in `NsfwDetector.instance.init(...)` to warm models on a splash screen — first scans become fast.

```dart
await NsfwDetector.instance.init(const NsfwInitOptions(
  preloadModels: [ModelIds.openNsfw2],
  downloadIfMissing: [], // add ids you want auto-downloaded on first launch
  enableNativeLogging: false,
));
```

If you skip `init`, the plugin lazy-loads on first use — no errors, just a slightly slower first scan.

Pick the entry point that matches your use case. Everything runs fully on-device.

### 1. `pickMedia` — easiest, no library permission

Opens the system picker, scans only what the user selected. Because the picker grants per-item access, you do **not** need full photo-library permission.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

final picked = await NsfwDetector.instance.pickMedia(
  type: MediaPickerType.any, // image | video | any
  multiple: true,
  maxItems: 5,
);

for (final item in picked) {
  final result = await NsfwDetector.instance.scanAsset(
    item.localId,
    confidenceThreshold: 0.75,
  );

  if (result.isNsfw) {
    // Block, blur, or route to review.
  }
}
```

Prefer `pickAndScan` if you want the picker and the scan in a single streamed call:

```dart
final session = await NsfwDetector.instance.pickAndScan(maxItems: 5);
session.results.listen((r) { if (r.isNsfw) { /* ... */ } });
await session.done;
```

### 2. `scanFile` / `scanBytes` — already have the media

Use these when your app already has a file path or raw bytes (captures, downloads, clipboard, generated images). No permission, no picker.

```dart
// From a path on disk
final result = await NsfwDetector.instance.scanFile(
  '/path/to/image.jpg',
  confidenceThreshold: 0.75,
);

if (result.isNsfw) {
  // Keep it local and show a policy message.
}

// From bytes in memory (Uint8List)
final fromBytes = await NsfwDetector.instance.scanBytes(imageBytes);

// One-shot boolean variants when you don't need the full result:
final flagged = await NsfwDetector.instance.isNsfwFile('/path/to/image.jpg');
```

### 2b. `NsfwModerationGate` — drop-in widget

Wrap any image-rendering widget and the gate blurs it if NSFW:

```dart
NsfwModerationGate.bytes(
  imageBytes,
  child: Image.memory(imageBytes),
  onResult: (r) => debugPrint('scanned: ${r.topCategory}'),
)
```

Available constructors: `.bytes(...)`, `.file(...)`, `.asset(...)`. Provide `nsfwBuilder` / `errorBuilder` for custom UI.

### 3. `startScan` — full photo library scan

Use this only when you want to scan a user's whole library. Requires photo-library permission.

```dart
// Combined permission request + scan — returns null on denial.
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  const ScanConfiguration.strict(includeVideos: true),
);
if (session == null) return; // Show your permission UI / fallback.

session.results.listen((r) { if (r.isNsfw) { /* ... */ } });
session.progress.listen((p) => debugPrint('${p.scannedCount}/${p.totalCount}'));

final summary = await session.done;
```

Presets available: `ScanConfiguration.strict()` (threshold 0.85), `.moderate()` (0.7), `.permissive()` (0.5), `.fastScan()` (concurrency 8). Equivalent presets for camera: `CameraConfiguration.realtime()`, `.balanced()`, `.batteryEfficient()`.

For camera scans, configuration details, and model handling, see the guides below.

## Documentation

- [Getting started](doc/getting-started.md)
- [Permissions](doc/permissions.md)
- [Media precheck](doc/media-precheck.md)
- [Picker workflows](doc/picker-workflows.md)
- [Library scanning](doc/library-scanning.md)
- [Camera scanning](doc/camera-scanning.md)
- [Configuration](doc/configuration.md)
- [Models](doc/models.md)
- [Privacy and limitations](doc/privacy-and-limitations.md)
- [Troubleshooting](doc/troubleshooting.md)

API reference is available on [pub.dev](https://pub.dev/documentation/nsfw_detect/latest/).

## Example app

Run the example app from the repository:

```bash
git clone https://github.com/nexas105/flutter_nsfw_scaner.git
cd flutter_nsfw_scaner/example
flutter pub get
flutter run
```

A real iOS or Android device is recommended for photo library and camera workflows. The example app demonstrates gallery scanning, headless API usage, result detail screens, model selection, confidence thresholds, and video frame options.

## Privacy

`nsfw_detect` is designed for local-first media analysis.

- Inference runs on-device
- Inference runs in the native iOS and Android layers
- The plugin does not include analytics or telemetry
- Picker-based scanning can avoid full photo-library permission

Your app is still responsible for explaining permissions, handling results, storing any moderation state, and complying with platform, privacy, and safety requirements.

## Limitations

NSFW detection is probabilistic. Results can include false positives and false negatives, especially with unusual lighting, partial visibility, illustrations, screenshots, low-resolution media, compressed videos, or ambiguous content.

Tune confidence thresholds for your product risk. For sensitive workflows, combine on-device detection with user reporting, human review, policy-specific rules, or other moderation layers.

## Package links

- [pub.dev package](https://pub.dev/packages/nsfw_detect)
- [API documentation](https://pub.dev/documentation/nsfw_detect/latest/)
- [GitHub repository](https://github.com/nexas105/flutter_nsfw_scaner)
- [Issue tracker](https://github.com/nexas105/flutter_nsfw_scaner/issues)
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
