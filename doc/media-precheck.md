# Media Prechecks

Use media prechecks to scan media before your app uses it. The plugin runs inference on-device and returns a moderation signal your app can use to allow, block, blur, or route media to review.

## Scan a local file before sharing

```dart
Future<bool> canUseFile(String path) async {
  final result = await NsfwDetector.instance.scanFile(
    path,
    confidenceThreshold: 0.75,
  );

  if (result.isNsfw) {
    return false;
  }

  return true;
}
```

## Scan image bytes

Use `scanBytes` for captures, generated images, downloaded images, clipboard images, or any image already represented as `Uint8List`.

```dart
final result = await NsfwDetector.instance.scanBytes(
  imageBytes,
  confidenceThreshold: 0.75,
);

if (result.isNsfw) {
  // Keep the media local and show a policy message.
} else {
  // Continue with your normal flow.
}
```

## Suggested policy flow

1. Scan locally before sharing.
2. Treat `nudity` and `explicitNudity` above threshold as blocked or review-required.
3. Decide whether `suggestive` should be allowed, warned, or reviewed for your app.
4. Keep a fallback for `unknown` and failed scans.
5. Avoid claiming the check is definitive.

## Handling failed scans

```dart
final result = await NsfwDetector.instance.scanFile(path);

if (result.status == ScanStatus.failed) {
  // Choose a conservative fallback for your product.
  // For example: require manual review or ask the user to retry.
}
```

False positives and false negatives are possible. For sensitive products, combine on-device checks with user reporting, human review, or policy-specific rules.
