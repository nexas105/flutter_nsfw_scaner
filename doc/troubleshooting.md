# Troubleshooting

## Photo-library scan does not start

Check permission status before calling `startScan`:

```dart
final status = await NsfwDetector.instance.checkPermission();
debugPrint(status.name);
```

`authorized` and `limited` can scan. `denied` and `restricted` need fallback UI or settings instructions.

Also verify platform setup:

- iOS has `NSPhotoLibraryUsageDescription`.
- iOS deployment target is 16.0 or higher.
- Android manifest includes the media permissions your workflow needs.

## Picker scan returns no results

If the user cancels the picker, `pickAndScan` completes with a zero-item summary.

```dart
final summary = await session.done;

if (summary.totalScanned == 0) {
  // Treat as user cancellation or empty selection.
}
```

## Camera scan fails

Check camera permission and listen for stream errors:

```dart
final session = await NsfwDetector.instance.startCameraScan();

session.results.listen(
  (result) {},
  onError: (error) {
    if (error is CameraPermissionDeniedException) {
      // Ask for permission or open settings.
    } else if (error is CameraErrorException) {
      debugPrint(error.toString());
    }
  },
);
```

Only one camera scan can run at a time. Call `stopCameraScan` before starting a new session.

## Scans are slow

Try:

- Lower `maxVideoFrames`.
- Increase `videoFrameInterval`.
- Keep `concurrency` near the default unless you have measured gains.
- Use cached library scans with `skipAlreadyScanned: true`.
- Keep camera `fps` and `resolution` conservative.
- Test Android `gpu` or `nnapi` delegates on your device matrix.

## Cached results are stale

Force a full rescan:

```dart
await NsfwDetector.instance.startScan(
  const ScanConfiguration(forceRescan: true),
);
```

Or clear the cache:

```dart
await NsfwDetector.instance.clearScanCache();
```

## Optional model is unavailable

List models and check availability:

```dart
final models = await NsfwDetector.instance.availableModels();

for (final model in models) {
  debugPrint('${model.id}: ${model.isAvailable}');
}
```

If a model requires download, call `downloadModel` and handle failure with retry UI or a fallback model.

## Need more logs

Enable native logging early in app startup or before the workflow you are debugging:

```dart
await NsfwDetector.instance.setLogging(true);
```

Disable it again when detailed logs are no longer needed:

```dart
await NsfwDetector.instance.setLogging(false);
```

## See also

- [Platform gotchas](platform-gotchas.md) — iOS HEIC, limited library, App Store Privacy Manifest, Android Photo Picker, ProGuard / R8 rules, minSdk implications.
- [Performance tuning](performance-tuning.md) — concurrency, cache, frame counts, FPS, delegates.
- [False positives FAQ](false-positives-faq.md) — threshold calibration and per-product tuning.
