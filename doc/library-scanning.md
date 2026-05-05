# Library Scanning

Use `startScan` to scan a photo library or a fixed set of asset identifiers. Results and progress stream while the native scanner processes media.

## Start a scan

```dart
final status = await NsfwDetector.instance.requestPermission();

if (status != PhotoLibraryPermissionStatus.authorized &&
    status != PhotoLibraryPermissionStatus.limited) {
  return;
}

final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(
    confidenceThreshold: 0.75,
    includeVideos: true,
    includeLivePhotos: true,
  ),
);

session.results.listen((result) {
  if (result.isNsfw) {
    // Save moderation state or update a gallery tile.
  }
});

session.progress.listen((progress) {
  // Render scannedCount / totalCount in your UI.
});

final summary = await session.done;
```

## Caching large libraries

The plugin can skip assets whose local identifier, model id, and modification date match a cached result.

```dart
const config = ScanConfiguration(
  skipAlreadyScanned: true,
  replayCachedResults: true,
);
```

Set `replayCachedResults: false` for delta-style scans where you only want newly scanned assets.

Use `forceRescan: true` for a manual "rescan all" action:

```dart
final session = await NsfwDetector.instance.startScan(
  const ScanConfiguration(forceRescan: true),
);
```

Clear the persistent cache when needed:

```dart
await NsfwDetector.instance.clearScanCache();
await NsfwDetector.instance.clearScanCache(modelId: ModelIds.openNsfw2);
```

## Video scanning

Video scans sample frames instead of inspecting every frame.

```dart
const config = ScanConfiguration(
  includeVideos: true,
  maxVideoFrames: 8,
  videoFrameInterval: 2.0,
);
```

Higher frame counts can improve coverage but increase scan time and battery use.

## Cancel a scan

```dart
await session.cancel();
```

The `done` future completes with `wasCancelled` set on the summary.
