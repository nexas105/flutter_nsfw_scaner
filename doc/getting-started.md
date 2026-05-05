# Getting Started

## Install

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

`result.isNsfw` is true only when the scan completed, the top category is `nudity` or `explicitNudity`, and confidence is at or above the configured threshold.

## Basic library scan

Library scans require photo-library permission. Picker scans do not require full library permission because the system picker grants access to selected media.

```dart
final status = await NsfwDetector.instance.requestPermission();

if (status != PhotoLibraryPermissionStatus.authorized &&
    status != PhotoLibraryPermissionStatus.limited) {
  return;
}

final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(confidenceThreshold: 0.75),
);

session.results.listen((result) {
  if (result.isNsfw) {
    // Store moderation state or update the UI.
  }
});

final summary = await session.done;
```

## Result categories

| Category | `isNsfw` category | Typical handling |
| --- | --- | --- |
| `safe` | No | Allow or continue |
| `suggestive` | No | Optional warning or review depending on policy |
| `nudity` | Yes | Block, blur, review, or ask for another file |
| `explicitNudity` | Yes | Block or require review |
| `unknown` | No | Treat according to your fallback policy |

Detection is probabilistic. Do not present results as guarantees.
