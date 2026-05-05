# Models

`nsfw_detect` exposes model metadata through `ModelDescriptor` and model operations through `NsfwDetector.instance`.

## Built-in model IDs

Use the exported constants where possible:

```dart
ModelIds.openNsfw2
ModelIds.falconsai
ModelIds.adamcodd
ModelDescriptor.nudenet
```

`ModelIds.openNsfw2` is the default classifier model. `ModelDescriptor.nudenet` is intended for detection mode with bounding boxes.

## List available models

```dart
final models = await NsfwDetector.instance.availableModels();

for (final model in models) {
  debugPrint(
    '${model.id}: ${model.displayName} '
    'available=${model.isAvailable} '
    'size=${model.downloadSizeLabel}',
  );
}
```

`model.isAvailable` is true when the model is bundled or already downloaded.

## Preload a model

Preload before the first scan when you want to reduce latency in a critical flow.

```dart
await NsfwDetector.instance.preloadModel(ModelIds.openNsfw2);
```

## Download an optional model

```dart
final ok = await NsfwDetector.instance.downloadModel(ModelDescriptor.nudenet);

if (!ok) {
  // Keep using an available bundled model or show retry UI.
}
```

Track download progress:

```dart
final sub = NsfwDetector.instance.downloadProgress.listen((progress) {
  debugPrint('${progress.modelId}: ${progress.bytesLabel}');
});

await NsfwDetector.instance.downloadModel(ModelDescriptor.nudenet);
await sub.cancel();
```

## Use a custom model URL

Use a CDN or mirror when your product needs to control model hosting.

```dart
await NsfwDetector.instance.setModelUrl(
  ModelIds.falconsai,
  'https://cdn.example.com/models/falconsai_nsfw.zip',
);

await NsfwDetector.instance.downloadModel(ModelIds.falconsai);
```

Or pass the URL for a single download:

```dart
await NsfwDetector.instance.downloadModel(
  ModelIds.falconsai,
  url: 'https://cdn.example.com/models/falconsai_nsfw.zip',
);
```

## Delete a downloaded model

```dart
await NsfwDetector.instance.deleteModel(ModelDescriptor.nudenet);
```

Deleting a model removes local model storage for that model. Your app should handle follow-up scans by downloading again or choosing an available model.
