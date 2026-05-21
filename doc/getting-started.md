# Getting Started

## Install

```yaml
dependencies:
  nsfw_detect: ^2.2.0
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

## Optional one-time init

Call `init` from your bootstrap to preload models and hide cold-start latency. Skipping it is fine — the plugin lazy-loads on first use.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NsfwDetector.instance.init(NsfwInitOptions(
    preloadModels: [ModelIds.openNsfw2],
    enableNativeLogging: kDebugMode,
    defaultThreshold: 0.75, // used when scan calls omit confidenceThreshold
  ));
  runApp(const MyApp());
}
```

Use `NsfwInitOptions.lazy()` or `NsfwInitOptions.debug()` for the common shapes. Call `reinit(options)` to reconfigure at runtime (toggle logging, swap models). See the [models guide](models.md) for `NsfwModelManager` — the high-level facade behind `NsfwDetector.instance.models`.

## Basic file scan

Use `scanFile` when media is already available as a local path, such as an media attachment, document picker result, app sandbox file, or temporary camera capture.

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

final result = await NsfwDetector.instance.scanFile(
  file.path,
  confidenceThreshold: 0.75,
);

switch (result.topCategory) {
  case NsfwCategory.nudity:
  case NsfwCategory.explicitNudity:
    // Stop the action, blur the preview, or route to review.
    break;
  case NsfwCategory.safe:
  case NsfwCategory.suggestive:
  case NsfwCategory.unknown:
    // Continue with your normal flow or apply your own policy.
    break;
}
```

`result.isNsfw` is true only when the scan completed, the top category is `nudity` or `explicitNudity`, and confidence is at or above the configured threshold. For a simple yes/no check, use the `isNsfwFile` / `isNsfwBytes` shortcuts.

Omit `confidenceThreshold` to fall back to the value set via [`NsfwInitOptions.defaultThreshold`](#optional-one-time-init).

## Basic library scan

Library scans require photo-library permission. Picker scans do not require full library permission because the system picker grants access to selected media.

```dart
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  const ScanConfiguration.strict(includeVideos: true),
);
if (session == null) return; // User denied — show your permission UI.

session.results.listen((result) {
  if (result.isNsfw) {
    // Store moderation state or update the UI.
  }
});

final summary = await session.done;
```

`ScanConfiguration` ships with `.strict()` (threshold 0.85), `.moderate()` (0.7), `.permissive()` (0.5), and `.fastScan()` (concurrency 8) presets — see the [configuration guide](configuration.md).

## Result categories

| Category | `isNsfw` category | Typical handling |
| --- | --- | --- |
| `safe` | No | Allow or continue |
| `suggestive` | No | Optional warning or review depending on policy |
| `nudity` | Yes | Block, blur, review, or ask for another file |
| `explicitNudity` | Yes | Block or require review |
| `unknown` | No | Treat according to your fallback policy |

Detection is probabilistic. Do not present results as guarantees.
