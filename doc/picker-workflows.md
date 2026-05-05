# Picker Workflows

Picker workflows are useful when users select media from the system picker. They avoid full photo-library permission because the picker grants access to selected items.

## Pick and scan immediately

Use `pickAndScan` when your app can classify selected media before showing a custom preview.

```dart
final session = await NsfwDetector.instance.pickAndScan(
  maxItems: 5,
  config: const ScanConfiguration(confidenceThreshold: 0.75),
);

session.results.listen((result) {
  if (result.isNsfw) {
    // Remove from the pending media list or mark for review.
  }
});

final summary = await session.done;
```

If the user cancels the picker, `session.done` resolves with a zero-item summary.

## Pick first, scan later

Use `pickMedia` when you need your own preview, selection, or edit screen before scanning.

```dart
final items = await NsfwDetector.instance.pickMedia(
  type: MediaPickerType.any,
  multiple: true,
  maxItems: 10,
);

for (final item in items) {
  final result = await NsfwDetector.instance.scanAsset(
    item.localId,
    confidenceThreshold: 0.75,
  );

  if (result.isNsfw) {
    // Update your selection state.
  }
}
```

## Scan a fixed selected subset

`ScanConfiguration.assetIdentifiers` lets you run a session against specific picked assets.

```dart
final selected = await NsfwDetector.instance.pickMedia(
  multiple: true,
  maxItems: 20,
);

final session = await NsfwDetector.instance.startScan(
  ScanConfiguration(
    assetIdentifiers: selected.map((item) => item.localId).toList(),
    confidenceThreshold: 0.75,
  ),
);
```

## UI helper

`NsfwPickerButton` provides a ready-made picker entry point when you want package UI instead of a custom button.

Use picker workflows when practical. They keep the permission surface smaller and support local-first precheck flows.
