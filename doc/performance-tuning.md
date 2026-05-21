# Performance Tuning

Knobs that move scan latency and battery draw, with concrete trade-offs.

> Reference numbers below were measured on an **iPhone 14 (A15, 6 GB RAM)** with the default `ModelIds.openNsfw2` classifier against a 10 000-image local library, unless stated otherwise. Treat them as planning figures, not benchmarks for your device matrix.

## Tuning matrix — library scans

| Configuration | Concurrency | Cache | ROI | Wall-clock (10 k images) |
| --- | --- | --- | --- | --- |
| Default (`ScanConfiguration()`) | 4 | enabled | full image | ~3 min |
| `.fastScan()` | 8 | enabled | full image | ~90 s |
| Second pass (warm cache, no changes) | 4 | replay only | — | ~5 s |
| Detection mode + NudeNet | 4 | enabled | full image | ~6 min |
| Detection mode + face-only ROI (planned) | 4 | enabled | face crop | ~45 s |

## Concurrency

`ScanConfiguration.concurrency` controls how many assets the native scanner processes in parallel. Default is 4; `.fastScan()` raises it to 8.

- Above ~8 the ANE/GPU saturates and additional workers just compete for memory.
- Raising concurrency increases peak memory; on lower-end devices (< 4 GB RAM) it can trigger jetsam.
- Concurrency does **not** affect single-call APIs (`scanFile`, `scanBytes`). They run one at a time by design.

## Cache hit ratios

`skipAlreadyScanned: true` (the default) keys a per-asset cache on `(localId, modelId, modificationDate)`. A second sync of an unchanged library skips inference entirely.

- Expected hit ratio on the first re-sync of a stable library: 100%.
- Add a new model and the cache invalidates only for that `modelId`; previously cached models remain valid.
- Use `replayCachedResults: false` for delta-style scans where you only want results for newly added or modified assets.
- Use `forceRescan: true` for a manual "rescan all" pass; the cache is overwritten on completion.

## Video frame counts

`maxVideoFrames` × `videoFrameInterval` defines the temporal sampling grid. Uniform sampling, hard-threshold fast-exit (any frame > 0.9 short-circuits the rest), center-weighted aggregation.

| `maxVideoFrames` | Coverage | Per-video latency (≈10 s clip) | Use case |
| --- | --- | --- | --- |
| 3 | Lowest — title card + middle + end | ~0.4 s | Quick first-pass triage |
| 5 | Balanced (default-ish) | ~0.7 s | Standard moderation |
| 10 | High — catches transient frames | ~1.4 s | Pre-publish gate, low-volume |

Pair higher counts with `skipAlreadyScanned: true` so the cost is paid once.

## Camera FPS trade-offs

`CameraConfiguration.fps` is bounded 1–30. The plugin throttles via an FPS gate before frames reach inference.

| `fps` | CPU/ANE load | Battery impact | UX | Use case |
| --- | --- | --- | --- | --- |
| 1 | Lowest | Minimal | Noticeably laggy reaction to scene changes | Background sentinel |
| 2 (default) | Low | Light | Comfortable for moderation overlays | Default |
| 5 | Moderate | Noticeable warmth on long sessions | Snappier blur transitions | Live preview gate |

Above ~5 fps the inference pipeline becomes the bottleneck and frames queue up; the throttle drops them rather than building latency.

## Low-power mode

iOS reports low-power mode via `ProcessInfo.isLowPowerModeEnabled`. The plugin does not auto-throttle; your app should branch on it.

```dart
if (ProcessInfo.processInfo.isLowPowerModeEnabled) {
  await NsfwDetector.instance.startCameraScan(
    const CameraConfiguration.batteryEfficient(),
  );
} else {
  await NsfwDetector.instance.startCameraScan(
    const CameraConfiguration.balanced(),
  );
}
```

On Android, check `PowerManager.isPowerSaveMode` through your host code if you need the same branch.

## ROI scanning

Region-of-interest scanning crops the input before inference. Smaller input → faster Core ML / TFLite execution.

- Detection mode + a downstream filter on body-part labels is the closest first-class API today: route through `ModelDescriptor.nudenet` in detection mode, then act only on the `*_EXPOSED` classes.
- For pure classification, you can pre-crop in your app (e.g. via `dart:ui`) and call `scanBytes` on the crop. Useful when you already have face detection upstream and want to focus inference on torso crops.
- A face-only ROI helper is on the roadmap; until then, use detection mode as the structured equivalent.

## Inference acceleration

### iOS — Core ML compute units

`ScanConfiguration.iosComputeUnits` selects which Apple silicon path Core ML uses.

| Setting | Behaviour |
| --- | --- |
| `IosComputeUnits.all` (default) | Apple chooses; usually ANE + GPU fallback. |
| `cpuAndNeuralEngine` | Skips the GPU. Faster on older devices without a dedicated ANE → GPU bridge. |
| `cpuOnly` | Deterministic, slowest. Useful for reproducibility tests. |

### Android — TFLite delegates

`ScanConfiguration.androidDelegate` opts into the GPU or NNAPI delegate.

| Setting | Behaviour |
| --- | --- |
| `null` (default) | CPU. Stable on every device. |
| `AndroidDelegate.gpu` | Uses `litert-gpu`. Faster on most modern GPUs; falls back to CPU silently if the delegate cannot be loaded. |
| `AndroidDelegate.nnapi` | Uses the device NNAPI driver. Faster on Pixels and some Samsung devices; less consistent than GPU across the device matrix. |

Always test delegate paths on your real device matrix — GPU/NNAPI behaviour is notoriously vendor-specific.

## Quick start by use case

| Goal | Configuration |
| --- | --- |
| First-time library sweep | `ScanConfiguration.fastScan()` + `skipAlreadyScanned: true` |
| Daily incremental sync | `ScanConfiguration.moderate()` (cache does the heavy lifting) |
| Pre-publish single image | `scanFile(path)` with `confidenceThreshold: 0.85` |
| Camera live preview | `CameraConfiguration.balanced()` |
| Low-power / background | `CameraConfiguration.batteryEfficient()` |
| Diagnostics / reproducibility | `iosComputeUnits: cpuOnly`, `androidDelegate: null` |
