# Camera Scanning

Camera scanning classifies live frames on-device. It is useful for preview moderation, guided capture, or parent-controlled camera features.

Only one camera session can run at a time.

## Drop-in camera widget

```dart
NsfwCameraView(
  config: const CameraConfiguration(
    fps: 2,
    mode: ScanMode.classification,
    confidenceThreshold: 0.75,
  ),
  showHudOverlay: true,
  enableBlurOnNsfw: true,
  onResult: (result) {
    if (result.isNsfw) {
      // Disable capture, blur preview, or show review UI.
    }
  },
  onPermissionDenied: () {
    // Show your own permission UI.
  },
);
```

## Headless camera scan

```dart
final session = await NsfwDetector.instance.startCameraScan(
  const CameraConfiguration(
    fps: 4,
    resolution: CameraResolution.medium,
    confidenceThreshold: 0.75,
  ),
);

session.results.listen(
  (result) {
    if (result.isNsfw) {
      // React to the current frame.
    }
  },
  onError: (error) {
    if (error is CameraPermissionDeniedException) {
      // Prompt the user or show settings instructions.
    }
  },
);

await NsfwDetector.instance.stopCameraScan();
```

## Detection mode with boxes

Use detection mode with a detector model when you need body-part bounding boxes.

```dart
const config = CameraConfiguration(
  modelId: ModelDescriptor.nudenet,
  mode: ScanMode.detection,
  detectionConfidenceThreshold: 0.25,
  iouThreshold: 0.45,
);
```

`CameraFrameResult.detections` contains normalized boxes when detections are available.

## Performance notes

- Start with `fps: 2` or `fps: 4`.
- Use `CameraResolution.medium` unless the product needs higher detail.
- Higher frame rates and resolutions increase CPU, GPU, battery, and heat.
- Android GPU or NNAPI delegates can be faster on some devices, but CPU is the safest default.
