# nsfw_detect Documentation

`nsfw_detect` adds local-first NSFW detection to Flutter apps. It can classify images, videos, selected media, photo libraries, files, bytes, and live camera frames using on-device inference.

Your app decides how to use the probabilistic moderation signal.

## Guides

- [Getting started](getting-started.md)
- [Permissions](permissions.md)
- [Media prechecks](media-precheck.md)
- [Picker workflows](picker-workflows.md)
- [Library scanning](library-scanning.md)
- [Camera scanning](camera-scanning.md)
- [Configuration](configuration.md)
- [Models](models.md)
- [Privacy and limitations](privacy-and-limitations.md)
- [Troubleshooting](troubleshooting.md)

## Core APIs

Most integrations start with `NsfwDetector.instance`:

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

final result = await NsfwDetector.instance.scanFile(
  file.path,
  confidenceThreshold: 0.75,
);

if (result.isNsfw) {
  // Blur, block, review, or ask the user to choose another file.
}
```

Use the result as one moderation signal. Tune thresholds for your product, and combine the signal with review flows when mistakes would have high impact.
