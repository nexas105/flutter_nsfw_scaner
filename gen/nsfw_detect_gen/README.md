# nsfw_detect_gen

Code generator for the `@NsfwModel` annotation shipped with the
[`nsfw_detect`](https://pub.dev/packages/nsfw_detect) Flutter plugin.

The annotation lives in the **main** package — `nsfw_detect_gen` is an opt-in
`dev_dependency` you pull in only when you want a generated registry.

## Install

```yaml
# pubspec.yaml
dependencies:
  nsfw_detect: ^2.2.0

dev_dependencies:
  build_runner: ^2.4.0
  nsfw_detect_gen: ^0.1.0
```

> **Heads-up:** the main `nsfw_detect` package does **NOT** depend on
> `nsfw_detect_gen`. Apps that don't need code-gen keep working unchanged.

## Annotate

```dart
// lib/my_models.dart
import 'package:nsfw_detect/nsfw_detect.dart';

part 'my_models.g.dart';

class MyModels {
  @NsfwModel(
    id: 'opennsfw2_coreml',
    defaultThreshold: 0.6,
    displayName: 'OpenNSFW 2',
    tags: {'classification', 'open-source'},
  )
  static const String openNsfw2 = 'opennsfw2_coreml';

  @NsfwModel(
    id: 'nudenet',
    defaultThreshold: 0.7,
    defaultMode: ScanMode.detection,
    displayName: 'NudeNet',
    tags: {'detection', 'permissive-license'},
  )
  static const String nudeNet = 'nudenet';
}
```

## Generate

```bash
dart run build_runner build --delete-conflicting-outputs
```

This emits `lib/my_models.g.dart` containing:

* `class _$MyModelsRegistry` with typed accessors:
  ```dart
  String get openNsfw2 => 'opennsfw2_coreml';
  double get openNsfw2Threshold => 0.6;
  ```
* A `Map<String, NsfwModel> models` literal keyed by id.
* `Future<void> registerAll(NsfwDetector detector)` — calls
  `detector.models.ensureReady(...)` for every annotated id.

## Use

```dart
import 'package:nsfw_detect/nsfw_detect.dart';
import 'my_models.dart';

Future<void> bootstrap() async {
  await myModelsRegistry.registerAll(NsfwDetector.instance);
  final result = await NsfwDetector.instance.scanBytes(
    bytes,
    modelId: myModelsRegistry.openNsfw2,
    confidenceThreshold: myModelsRegistry.openNsfw2Threshold,
  );
}
```

## Example

See `example/` for a runnable annotated class plus the generated `.g.dart`.

## License

Same license as the main `nsfw_detect` package — see the repo root.
