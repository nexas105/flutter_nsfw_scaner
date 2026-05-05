# nsfw_detect_ios — Example App

Demonstrates all features of the [`nsfw_detect_ios`](https://pub.dev/packages/nsfw_detect_ios) Flutter plugin.

## Screens

### Gallery (tab 1)

Full photo-library scan powered by `NsfwGalleryView`.

- Live result grid — tiles update with NSFW badge overlays as each asset is classified
- Tap any tile to open the Detail screen
- NSFW counter chip in the app bar updates on scan completion
- Settings screen: model picker, confidence threshold slider, video frame options

### Headless (tab 2)

Pure Dart API demo — no plugin widgets involved. Wires `NsfwDetector.instance` manually
to demonstrate the headless usage pattern:

```dart
// 1. Check / request permission
final status = await NsfwDetector.instance.requestPermission();

// 2. Configure
const config = ScanConfiguration(
  confidenceThreshold: 0.65,
  includeVideos: false,
  concurrency: 3,
);

// 3. Start scan
final session = await NsfwDetector.instance.startScan(config);

// 4. Listen to streams
session.results.listen((result) { /* ... */ });
session.progress.listen((p) { /* ... */ });

// 5. Await summary
final summary = await session.done;
```

Displays a colour-coded event log (info / NSFW / safe / error) and a live progress bar.

### Detail screen

Opened by tapping a tile in the Gallery screen.

- Full-resolution asset preview
- `NsfwResultBadge` in detailed style
- Classification breakdown — confidence bar per category
- Body part detection list with severity chips and per-detection confidence bars
- Asset metadata (type, resolution, creation date, scan timestamp)

## Running

```bash
cd example
flutter pub get
cd ios && pod install && cd ..
flutter run
```

> A real iOS 16+ or Android device is required — photo library access is not available
> on simulators / emulators.
