# nsfw_detect Documentation

`nsfw_detect` adds local-first NSFW detection to Flutter apps. It can classify images, videos, selected media, photo libraries, files, bytes, URLs, image providers, and live camera frames using on-device inference. Detection-mode models add body-part bounding boxes you can pipe straight into native redaction, and the detect-then-classify pipeline attaches per-region NSFW labels to each box.

Your app decides how to use the probabilistic moderation signal.

## Start here

- [Getting started](getting-started.md) — install, init, first scan.
- [Cookbook](cookbook.md) — copy-pasteable recipes: gating, library scans, per-category thresholds, decision store, detect-then-classify, telemetry hooks, localization, and more.

## Workflow guides

- [Permissions](permissions.md) — runtime permission flows on iOS / Android, plus `NsfwPermissionsView`.
- [Media prechecks](media-precheck.md) — using the `isNsfw*` shortcuts before heavier work.
- [Picker workflows](picker-workflows.md) — `pickMedia`, `pickAndScan`, per-item access.
- [Library scanning](library-scanning.md) — `startScan` with checkpointing, throttling, ROI.
- [Camera scanning](camera-scanning.md) — `startCameraScan`, `NsfwCameraView`, FPS knobs.

## Reference

- [Configuration](configuration.md) — `ScanConfiguration` / `CameraConfiguration` presets, knobs, and per-category thresholds.
- [Models](models.md) — `NsfwModelManager`, custom URLs, on-demand downloads, SHA-256 pinning, custom-model registration, detect-then-classify.
- [Platform gotchas (iOS / Android)](platform-gotchas.md) — `Info.plist` keys, `AndroidManifest.xml`, ProGuard rules.
- [Performance tuning](performance-tuning.md) — concurrency, FPS, compute units, throughput tradeoffs.
- [False positives FAQ](false-positives-faq.md) — threshold tuning, model selection, common pitfalls.
- [Privacy and limitations](privacy-and-limitations.md) — what the plugin promises and where it doesn't.
- [Troubleshooting](troubleshooting.md) — diagnostic errors, common fixes.

## Migration notes

- [Migration: 2.1 → 2.2](migration-2.1-to-2.2.md)

## Core APIs

Most integrations start with `NsfwDetector.instance`:

```dart
import 'package:nsfw_detect/nsfw_detect.dart';

final result = await NsfwDetector.instance.scanFile(
  file.path,
  confidenceThreshold: 0.75,
);

if (result.isNsfw) {
  // Blur, block, route to review, or ask for another file.
}
```

Use the result as one moderation signal. Tune thresholds for your product, and combine the signal with human review or reporting flows when mistakes would have high impact.

For the full picture of public entry points see the [cookbook](cookbook.md) — every common shape is one recipe away.

## API reference

Full Dart API reference on [pub.dev](https://pub.dev/documentation/nsfw_detect/latest/).
