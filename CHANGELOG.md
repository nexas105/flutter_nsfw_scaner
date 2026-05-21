## 2.2.0 — 2026-05-21

> v2.2.0 is a developer-experience release: a proper init/preload lifecycle, presets for common moderation tunings, batch + boolean shortcut APIs, a drop-in moderation gate widget, public JSON for `ScanResult`, and a high-level `NsfwModelManager` for download and warm-up.
>
> All changes are additive — existing 2.1.x code keeps working without changes.

### New — Init & model lifecycle

- **`NsfwDetector.instance.init([NsfwInitOptions])`** — single canonical bootstrap hook. Preloads models, optionally downloads missing ones, toggles native logging, and reports back via `NsfwInitReport` (`preloaded`, `downloaded`, `errors`, `elapsed`). Safe to call multiple times.
- **`NsfwInitOptions`** + `.lazy()` / `.debug()` named constructors for typical startup shapes. `defaultThreshold` is honoured by all scan APIs when the call omits an explicit threshold.
- **`NsfwDetector.reinit(options)`** — reconfigure after the first init (toggle logging, swap preloaded models). Awaits any in-flight init before starting the new pass.
- **`NsfwModelManager`** (via `NsfwDetector.instance.models`) — high-level model lifecycle facade: `preload`, `preloadAll`, `ensureReady` (download → load), `remove`, `refresh`, plus a `changes` stream of `ModelStateSnapshot` updates for UI state pills.
- **`NsfwDetector.downloadModelWithProgress(modelId, onProgress:)`** — Future-based wrapper around `downloadModel` + the existing progress stream. Resolves once the download is complete; throws `StateError` on native rejection.
- **`NsfwDetector.ready({modelId})`** — quick preload alias for splash screens.

### New — Configuration presets

- **`ScanConfiguration.strict()` / `.moderate()` / `.permissive()` / `.fastScan()`** — named presets so callers don't have to invent threshold values. Each accepts optional `modelId`, `includeVideos`, `includeLivePhotos`, `assetIdentifiers`, `mode` overrides.
- **`CameraConfiguration.realtime()` / `.balanced()` / `.batteryEfficient()`** — equivalent presets for live camera scans.

### New — Headless API shortcuts

- **`NsfwDetector.isNsfwFile` / `isNsfwBytes` / `isNsfwAsset`** — `Future<bool>` shortcuts for simple gate checks where you don't need the full `ScanResult`.
- **`NsfwDetector.scanFiles` / `scanAssets` / `scanAllBytes`** — sequential batch APIs with optional `onProgress(done, total)` callback. Per-item failures surface as a failed `ScanResult` so the batch always completes.
- **`NsfwDetector.requestPermissionAndStartScan(config)`** — combined permission + start-scan call. Returns `null` when the user denies access.

### New — Result ergonomics

- **`ScanResult.hasNudity` / `hasExplicitContent` / `isSuggestive` / `hasDetections`** — category-specific booleans on top of the existing `isNsfw`.
- **`ScanResult.confidenceDescription`** — human-readable bucket ("Very high" / "High" / "Moderate" / "Low" / "Very low") for logs and debug UIs.
- **Public `ScanResult.toJson()` / `ScanResult.fromJson(...)`** — `confidenceThreshold` is preserved so the round-trip is `isNsfw`-stable. Suitable for `shared_preferences` / disk caches.
- **`ScanResult.failed(...)` factory** — used internally by the new batch APIs to surface per-item errors deterministically; available to callers as well.
- **`ScanResult.fake(...)` test factory** (`@visibleForTesting`) — construct realistic results in unit tests without booting the platform channel.

### New — Result list extensions

- **`List<ScanResult>.newSince(previous)`** / **`changedFrom(previous)`** / **`countByCategory`** / **`nsfwOnly`** / **`completedOnly`** / **`failedOnly`** — aggregations and diffs over scan output without writing the boilerplate map / set logic each time.

### New — Permission ergonomics

- **`PhotoLibraryPermissionStatus.canScan`** — `true` for `authorized` and `limited`. Removes the repeated `if (status == .authorized || status == .limited)` check across apps.
- **`needsSettingsApp`** — `true` for `denied` and `restricted` (requests won't re-prompt).
- **`userMessage`** — short non-localised hint string for debug UIs.

### New — Widget

- **`NsfwModerationGate`** — drop-in widget that scans a source (`.bytes(...)` / `.file(...)` / `.asset(...)`), renders the child on safe, and blurs + overlays a warning on NSFW. Custom `nsfwBuilder`, `errorBuilder`, and `loading` slots for app-specific UI. Fails open by default (renders child on scan error); override `errorBuilder` to fail closed.

### Docs

- README Quickstart now leads with `pickMedia` (no library permission), then `scanFile` / `scanBytes`, then `startScan`. `init`, presets, and `NsfwModerationGate` are documented up front.

## 2.1.2 - 2026-05-21

- Expand the README Quickstart into three labelled entry points — `pickMedia` (no library permission required), `scanFile` / `scanBytes`, and `startScan` — so the simplest API surface is documented up front.

## 2.1.1 - 2026-05-05

- Refresh pub.dev presentation with a clearer privacy-first README, shorter quickstarts, use cases, setup guidance, FAQ, and neutral visual-asset suggestions.
- Add versioned `doc/` guides for getting started, permissions, media prechecks, picker workflows, library scanning, camera scanning, configuration, models, privacy, limitations, and troubleshooting.
- Expand Dartdoc coverage for the main detector APIs, scan and camera configuration, result types, sessions, controller lifecycle, and core widgets.
- Improve package metadata with repository, issue tracker, documentation, platform declarations, and search-friendly topics.
- Add GitHub issue and pull request templates for bug reports, feature requests, documentation issues, and contribution review.
- Exclude local agent/editor files from the published archive via `.pubignore`.
- Fix the example README package name and include the iOS example lockfile entry for `app_settings`.

## 2.1.0 — 2026-05-05

> v2.1.0 ships a live-camera detection pipeline alongside the existing photo-library scan, plus a reusable permissions UI widget and the missing `example/android/` shell.

### New — Live camera scan pipeline

- **`NsfwDetector.startCameraScan(CameraConfiguration?)` / `stopCameraScan()`** — single-session live detection. Returns a `CameraScanSession` whose `results` is a broadcast `Stream<CameraFrameResult>`. Concurrent sessions throw a `StateError`.
- **`CameraConfiguration`** — `modelId`, `confidenceThreshold`, `mode` (classification or detection), `fps` (1–30, default 2), `resolution` (`low` / `medium` / `high`), `detectionConfidenceThreshold`, `iouThreshold`, `iosComputeUnits`, `androidDelegate`. Same model surface as the photo-library API.
- **`CameraFrameResult`** — per-frame value type with `frameTimestamp`, sorted `labels`, optional `detections` (NudeNet boxes), tolerant `fromMap` parsing. `topCategory` / `topConfidence` / `isNsfw` mirror `ScanResult`.
- **`CameraPermissionDeniedException`, `CameraErrorException`** — surfaced as stream errors on `CameraScanSession.results` (not as null per-frame results).

### iOS native — AVCaptureSession + CoreML

- `ios/Classes/camera/CameraSessionTask.swift`, `CameraFrameProcessor.swift`, `CameraConfiguration.swift`, `permissions/CameraPermission.swift`.
- AVCaptureSession running at configurable FPS, frames thrown into the existing `MLEngine.classify(pixelBuffer:)` and `MLDetectorEngine.detect(pixelBuffer:)` paths — no duplicate inference code. Detection mode reuses NudeNet with NMS.
- Camera-permission flow via `AVCaptureDevice.authorizationStatus` / `requestAccess(for: .video)`.
- Lifecycle: `start`, `stop`, `restart` are graceful — no buffer leaks, CVBufferPool reuse.
- Events multiplexed onto the existing `nsfw_detect_ios/scan_events` `EventChannel` with `type` ∈ {`cameraFrameResult`, `cameraPermissionDenied`, `cameraError`} — no new channels.

### Android native — CameraX + TFLite

- `android/.../camera/CameraSessionTask.kt`, `CameraFrameAnalyzer.kt`, `FpsThrottle.kt`, `ImageProxyConverter.kt`, `CameraSessionConfig.kt`, `CameraPermission.kt`, `PluginLifecycleOwner.kt`.
- CameraX `ImageAnalysis` at the configured FPS, `ImageProxy → Bitmap → TFLite` reusing the existing `TFLiteEngine` and detector path. `ImageProxy.close()` in `finally` across all five analyzer branches.
- `DetectionAggregator` extracted from `ScanSessionTask.runDetectionScan` so the same body-part aggregation runs identically for library and camera frames (snapshot-compared — wire shape byte-identical).
- CameraX 1.3.4 (the last 1.3.x line) keeps `minSdkVersion 21` and stock `compileOptions`.

### Flutter — `NsfwCameraView`

- New widget: native preview via `UiKitView` (iOS) / `AndroidView` (Android) + HUD stack on top.
  - iOS PlatformView factory `nsfw_detect_ios/camera_preview` attaches `AVCaptureVideoPreviewLayer` (`resizeAspectFill`).
  - Android PlatformView wraps a `PreviewView` (`FILL_CENTER`); pulls in `androidx.camera:camera-view:1.3.4`.
- New `NsfwCameraHud` widget — confidence bar + category label + NSFW badge. Reuses `NsfwResultBadge` via a private `ScanResult` adapter (no duplicated badge code).
- Detection mode draws bounding boxes via the existing `NsfwDetectionOverlay` (it was already `Size`-agnostic).
- Optional **blur on NSFW** — `BackdropFilter` + `ImageFilter.blur` wrapped in `AnimatedSwitcher` so the blur fades in/out instead of strobing on borderline frames. Configurable `blurSigma` and `enableBlurOnNsfw`.
- Lifecycle bound to `initState` / `dispose`.
- `NsfwGalleryTheme` extended additively with four camera-only fields: `cameraBlurSigma`, `cameraBlurTintOpacity`, `cameraConfidenceBarHeight`, `cameraHudBackgroundOpacity`. Existing `NsfwGalleryTheme(...)` callers keep working unchanged.

### New — `NsfwPermissionsView`

- Reusable widget that surfaces every permission the plugin needs (photo library + camera) with status, an explainer, and a Request / Open Settings action button. Auto-refreshes when the app returns from system Settings (`WidgetsBindingObserver`).
- Plugin stays dependency-free — the "Open Settings" deep-link is delegated to the host app via the `onOpenSettings` callback. Example app pulls in `app_settings: ^5.1.1` to wire it.
- Wired into the example app's `SettingsScreen` above `NsfwSettingsPanel`.
- Themed via `NsfwTheme` semantic tokens (`success` / `accent` / `danger`), `Semantics`-wrapped for screen readers.
- New types in `lib/src/api/permissions/permission_kind.dart`: `PermissionKind` (`photoLibrary`, `camera`), `PermissionStatus` (`authorized`, `limited`, `denied`, `permanentlyDenied`, `restricted`, `notDetermined`), `PhotoLibraryPermissionStatusMapping` extension.

### Platform-interface additions

- `NsfwPlatformInterface.startCameraScan(CameraConfiguration)` / `stopCameraScan()` — abstract; every platform must implement. Wired in `NsfwMethodChannel`.
- `NsfwPlatformInterface.checkCameraPermission()` / `requestCameraPermission()` — non-abstract with `UnimplementedError` defaults so test mocks need only stub what they exercise. `NsfwMethodChannel` re-maps `MissingPluginException → UnimplementedError`; `NsfwDetector.checkCameraPermission()` / `requestCameraPermission()` catch and degrade gracefully to `PermissionStatus.notDetermined` on platforms without the native handler yet wired.

### Fixes

- **Concurrent-task crash in `ImageAnalyzer` (iOS).** `pixelBufferPool` was a `lazy var`; concurrent first-frame Tasks racing on the lazy initialisation produced a partially-written pointer, manifesting as `EXC_BAD_ACCESS` at `+0x18` inside `CVPixelBufferPool::createPixelBuffer` on cooperative-queue threads. Eager-init in `init()` instead — pool depends only on `inputSize`, no behaviour or perf change.
- **`scanAsset returns result` test regression.** Pre-existing failure on `main` from before v2.1.0: the mock fixture mixed `safe=0.95` with `nudity=0.03`, but `ScanResult.topCategory` has been NSFW-priority-sorted since v2.0 (commit `882ba2a`). Reduced the fixture to a single unambiguous label and added an explicit test that locks in the priority-sort contract.

### Example app

- `example/ios/Runner/Info.plist` — adds `NSCameraUsageDescription`. iOS killed the app on `AVCaptureDevice.requestAccess` without it.
- `example/android/app/src/main/AndroidManifest.xml` — adds `android.permission.CAMERA` + two optional `<uses-feature>` entries (`camera` + `camera.autofocus` with `required="false"`) so the Play Store doesn't filter the listing on cameraless devices.
- `example/lib/screens/settings_screen.dart` embeds `NsfwPermissionsView`; depends on `app_settings: ^5.1.1`.

### Tests

- 86 → 116 plugin unit + widget tests (`+30`). Camera HUD widget tests (Phase 4), `NsfwPermissionsView` tests covering all six `PermissionStatus` variants + lifecycle resume + UnimplementedError fallback, and the explicit NSFW-priority sort test.

### Migration

```dart
// New: live camera scan
final session = await NsfwDetector.instance.startCameraScan(
  const CameraConfiguration(fps: 2, mode: ScanMode.detection),
);
session.results.listen((CameraFrameResult r) {
  if (r.isNsfw) print('NSFW @ ${r.frameTimestamp}: ${r.topCategory}');
});
// Or drop in the widget — it manages the session itself:
NsfwCameraView(
  config: const CameraConfiguration(fps: 2),
  enableBlurOnNsfw: true,
  showHudOverlay: true,
);

// New: permissions widget
NsfwPermissionsView(
  theme: appNsfwTheme,
  onOpenSettings: AppSettings.openAppSettings, // host-app dep
);
```

iOS callers must add to `Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Live NSFW detection on the camera feed.</string>
```
Android callers must add to `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
```

---

## 2.0.1

- Doc cleanup. No code changes from 2.0.0.

---

## 2.0.0

### Breaking changes

- **`PickedMedia.mediaType` is now `MediaType` enum** (was `String`). `pickedMedia.mediaType == 'image'` → `pickedMedia.mediaType == MediaType.image`. Affects callers of `NsfwDetector.instance.pickMedia(...)`.

### Architecture — `NsfwGalleryView` is no longer a god-widget

- **`NsfwScanController` extracts gallery state into a `ChangeNotifier`.** Permission, scan session, item list, results map, progress and lifecycle methods (`startScan`, `stopScan`, `requestPermission`, `dispose`) live on the controller. Consumers can hold their own controller and bind multiple views to it, or rely on `NsfwGalleryView` to create+dispose one internally (default, BC).
- **`NsfwGalleryView.controller`** — new optional parameter. When `null`, the widget builds its own controller exactly like before. Otherwise the consumer owns the lifecycle.
- **`NsfwPlatformInterface` slimmer for mocks.** Optional methods (`preloadModel`, `downloadModel`, `deleteModel`, `setModelUrl`, `setLogging`, `clearScanCache`, `resetScan`, `pickMedia`, `scanFilePath`, `scanImageBytes`) ship default implementations — no-op or `UnimplementedError`. Test mocks now stub only the six lifecycle methods that actually matter.

### New API

- `NsfwScanController` — see above. Exported from `package:nsfw_detect/nsfw_detect.dart`.
- `MediaPickerType` lives in `lib/src/api/media_picker_type.dart` (was inlined). Re-exported.

### Internals & tests

- Test count `78 → 87` (`+9`): controller lifecycle, controller-vs-view interaction, `PickedMedia.mediaType` enum parsing, `MediaPickerType` standalone import.
- `NsfwGalleryView` shrunk from ~520 lines (logic + view) to a thin scaffold. Body is grid/skeleton/empty/permission render — driven by the controller.

### Migration

```dart
// PickedMedia.mediaType
- if (pm.mediaType == 'image') { ... }
+ if (pm.mediaType == MediaType.image) { ... }

// Optional: hold your own controller
final controller = NsfwScanController(initialConfig: ScanConfiguration());
NsfwGalleryView(controller: controller, ...);
// remember to controller.dispose() in your State.dispose()
```

---

## 1.3.0

### Object detection — body-part bounding boxes

- **NudeNet detector (iOS + Android).** New detection mode runs a YOLOv8-based 18-class body-part detector and emits bounding boxes per asset (e.g. `FEMALE_BREAST_EXPOSED`, `FEMALE_GENITALIA_COVERED`, …). Hosted as a downloadable model — `~46 MB` `.mlmodelc.zip` (CoreML, with NMS pipeline producing `VNRecognizedObjectObservation`) / `.tflite.zip` (TFLite raw YOLO; Kotlin runs class-aware NMS at IoU 0.45). `inputSize` 640 for accuracy.
- **`MLDetectorEngine` protocol (iOS + Android).** First-class peer to `MLEngine` so the registry can hold both classifier and detector kinds. `kind(for: id)` distinguishes the two; `detectorEngine(for:)` / `engine(for:)` route to the correct factory.
- **Detection-mode scan pipeline.** When `ScanConfiguration.mode == "detection"` (or the chosen `modelId` is registered as a detector), `ScanSessionTask` routes pixel buffers through `detect(...)` and aggregates per-category max confidence into `result.labels` so the existing `topCategory` / `isNsfw` semantics keep working — extra raw boxes are stashed on `result.detections`.
- **NSFW priority sort.** Detection aggregation now sorts categories by NSFW priority (`explicitNudity → nudity → suggestive → safe → unknown`) before confidence. A high-confidence `FACE_FEMALE` no longer outranks a moderate-confidence `FEMALE_BREAST_EXPOSED` — any `*_EXPOSED` hit at or above the detection threshold flips the result to NSFW.
- **`NsfwDetectionOverlay` widget.** Drop-in overlay that renders detection boxes + labels + confidence on top of any image tile. Categories colour-coded via the existing theme tokens.
- **`ScanCache` schema v2.** New `detections_json` column persists raw bounding boxes per cached entry; cache hits replay both labels and detections. Migrations are wrapped in transactions; downgrade drops + recreates.

### Models

- **`models-v1` GitHub Release** consolidates all on-device artefacts as a single source of truth (Falconsai, AdamCodd, OpenNSFW2, NudeNetDetector). Defaults in both registries point there.
- **Falconsai + AdamCodd Android.** TFLite parity. ViT normalisation `(2x − 1)` and softmax baked into the graph so Kotlin passes raw `[0, 1]` floats and reads `[0, 1]` probabilities directly — symmetric to iOS via `classifier_config`. INT8 weight-only post-quantisation gets the artefacts to ~75 MB without measurable accuracy loss.
- **Reproducible conversion.** New `tools/convert_models.py` (CoreML), `tools/convert_tflite.py` (TFLite, runs in a separate venv to avoid the LLVM CLI clash between `tensorflow` and `jax`), and `tools/convert_nudenet.py` (ultralytics YOLO export → both formats). Each script is idempotent and gates download-then-convert from the upstream HuggingFace / GitHub source.

### Fixes

- **`PHPhotosError 3303` fallback (iOS).** When `PHCachingImageManager` refuses an asset (limited library, iCloud-only without network, cache edge cases), the analyzer retries via `PHImageManager.default()` + `requestImageDataAndOrientation`. Recovers most assets that previously surfaced as opaque "pixelBuffer unavailable".
- **Detector preload (iOS).** `preloadModel` and the implicit preload inside `startScan` both went through the classifier-only `engine(for:)` factory map and 404'd every detector model. Routes now branch on `kind(for: id)`.
- **Softmax for ViT classifiers (iOS).** Falconsai / AdamCodd CoreML models emit raw logits via `classifier_config`. Vision passes those through as `confidence`, producing values like `nudity=357%, safe=−240%`. `CoreMLEngine` now applies a numerically-stable softmax client-side, so confidences land back in `[0, 1]` and the gallery's default `0..1` filter shows the NSFW hits.
- **Surfaced video skip reasons.** "Skipped" status now carries the underlying cause (zero-duration AVAsset, empty sample times, etc.) in `result.errorMessage` instead of disappearing silently.
- **Surfaced pixel-buffer errors.** Error from the per-asset image fetch is captured per-asset and propagated to `result.errorMessage` instead of being swallowed by `try?`.

### Performance — large library scans

- **Incremental scans (iOS + Android).** Per-asset cache keyed by `(localId, modelId, modificationDate)` persisted in SQLite. A second sync of an unchanged 200k-asset library skips the ML pipeline entirely — sub-second filter pass instead of minutes of inference.
- **Cached results are replayed by default.** `Stream<ScanResult>` stays complete; cached items are flagged via the new `ScanResult.fromCache: bool` so consumers can distinguish them.
- **Event-sink throttling (iOS).** Per-asset `result` events are coalesced into batched `results` channel messages (50 items / 100 ms), and `progress` events are throttled to ≤ 1 per 100 ms. Reduces IPC roundtrips by ~50–100× for large libraries.
- **Sliding-window prefetch (iOS).** `PHCachingImageManager` now releases older prefetch windows via `stopCachingImages(for:)`, keeping memory bounded regardless of library size (previously linear).
- **Real cache hits in the `ImageAnalyzer` pipeline (iOS).** Prefetched assets are now read through the same `PHCachingImageManager` with identical options — the prefetch was previously a no-op.
- **Throttled checkpoint writes (iOS).** Per-asset `UserDefaults` writes are coalesced (every 25 assets + at scan boundaries). Cuts disk I/O in the hot path proportionally.
- **Batched scan-cache writes (iOS + Android).** `ScanCache.record()` now buffers in memory and flushes in groups of 50 inside a single `BEGIN…COMMIT` transaction (iOS uses one prepared statement reused via `bind`/`step`/`reset`; Android uses `SQLiteStatement` + `beginTransaction`). 200k assets go from ~200k mini-transactions to ~4k. Reads call `flush()` first to keep lookups consistent.
- **`inSampleSize` downsampling on bitmap decode (Android).** `BitmapFactory.decodeStream(...)` previously did a full-resolution decode — a 12 MP photo allocated ~50 MB before being scaled to 224×224. Now a two-pass decode (`inJustDecodeBounds` + power-of-two `inSampleSize`) drops peak per-frame allocation by ~250×. Pendant to the iOS `ImageIO` thumbnail path.
- **Pooled `CVPixelBuffer` + cached `CGColorSpace` (iOS).** `ImageAnalyzer` now renders frames into buffers from a `CVPixelBufferPool` instead of `CVPixelBufferCreate` per frame, and the device RGB color space is allocated once statically. ~400k allocations eliminated on a 200k-asset scan.

### Performance — inference acceleration

- **Configurable Core ML compute units (iOS).** New `ScanConfiguration.iosComputeUnits` exposes `MLModelConfiguration.computeUnits`. Defaults to `.all`; `cpuAndNeuralEngine` or `cpuOnly` can be faster on older devices without a dedicated ANE (no GPU roundtrip).
- **TFLite GPU / NNAPI delegate (Android).** New `ScanConfiguration.androidDelegate` enables the `litert-gpu` or NNAPI delegate. Opt-in (default CPU) because GPU/NNAPI delegates are flaky on some device families. Falls back to CPU silently if the delegate cannot be loaded.
- **Reused `VNCoreMLRequest` (iOS).** `CoreMLEngine.classify(pixelBuffer:)` no longer allocates a Vision request per call. One request is built at `load()` time and reused under a serializing lock — only relevant when the batch path falls back, but cleaner and cheaper.

- **`OSAllocatedUnfairLock` for the scan counter (iOS 16+).** Hot-path counter swaps `NSLock` for `OSAllocatedUnfairLock<Int>`. 5–10× cheaper under contention.

### New API

- `ScanConfiguration.skipAlreadyScanned: bool` (default `true`) — skip assets matching a cached fingerprint.
- `ScanConfiguration.forceRescan: bool` (default `false`) — bypass the cache for this run; cache is overwritten on completion.
- `ScanConfiguration.replayCachedResults: bool` (default `true`) — emit cached results on hit; disable for "delta only" mode.
- `ScanConfiguration.iosComputeUnits: IosComputeUnits` (default `.all`) — selects the Core ML compute-unit preference on iOS.
- `ScanConfiguration.androidDelegate: AndroidDelegate?` (default `null` = CPU) — opt into the TFLite `gpu` or `nnapi` delegate on Android.
- `NsfwDetector.instance.pickMedia({type, multiple, maxItems})` — opens the native picker and returns the selected items as `List<PickedMedia>` without classifying. Pair with `scanAsset` for on-demand classification.
- `NsfwDetector.instance.clearScanCache({String? modelId})` — drop cached entries for one model or all.
- `ScanResult.fromCache: bool` — `true` when the result was replayed from the persistent cache.

### Internals

- Schema migrations for the scan cache via `PRAGMA user_version` (iOS) / `SQLiteOpenHelper.onUpgrade` (Android), wrapped in transactions; `onDowngrade` drops + recreates rather than failing.
- New `EventBatcher` and `CheckpointWriter` helpers in `ScanSessionTask.swift`.
- `MLEngine` protocol gains `setPreferredComputeUnits(_:)` / `loadedComputeUnits`; `ModelRegistry.engine(for:computeUnits:)` recreates the cached engine if the preference changes.

### Demo app

- New "Skip Already Scanned" and "Force Rescan" toggles in the settings screen.
- New "Clear Scan Cache" maintenance action.

---

## 1.2.8

### Fixes

- Fixed `ModelIds.adamcodd` runtime classification mapping on iOS (AdamCodd output classes now map correctly to plugin categories).
- Fixed model-size handling for AdamCodd (ViT-384) in video frame sampling and file/bytes scan preprocessing.

---

## 1.2.7

### Performance

- Improved runtime threshold consistency across native processing paths.
- Further stability refinements in background task flow under high load.

### Known issue

- `ModelIds.adamcodd` is currently not functional at runtime. Use `ModelIds.openNsfw2` or `ModelIds.falconsai`.

---

## 1.2.6

### Performance

- Improved native runtime scheduling stability during long scans.
- Reduced unnecessary cancellation side effects in background task orchestration.

---

## 1.2.5

### Fixes

- Fixed example app compile issues by removing obsolete detection-only UI code from the detail screen.
- Added a visible maintenance action in example settings to trigger `NsfwDetector.resetScan()`.

---

## 1.2.4

### Performance

- iOS method-channel heavy operations now run with utility-priority tasks to avoid accidental UI-thread contention during preload, model download, scanFile, scanBytes, and scanSingleAsset.
- Android background dispatch switched from per-asset raw thread spawning to a bounded native worker pool with backpressure, reducing thread churn and frame-drop risk under large scans.

---

## 1.2.3

### New features

- Added `NsfwDetector.resetScan()` to reset native scan runtime state.
- Implemented native handling on iOS and Android (`resetScan` method-channel call).

---

## 1.2.2

### Maintenance

- Native logging cleanup in platform internals.
- No API changes.

---

## 1.2.1

### Maintenance

- Updated package metadata/topics for pub.dev discovery (`nsfw-detection`, `nudity-detection`).
- Version sync/release housekeeping (`pubspec.yaml` + iOS podspec).
- Minor runtime/performance cleanup: reduced logging overhead in native processing paths.
- No API changes.

---

## 1.2.0

### New features

- **`NsfwDetector.pickAndScan({int maxItems})`** — opens the native iOS `PHPickerViewController`
  (or Android photo picker on API 33+) and scans the selected photos/videos. Returns a
  `ScanSession` that streams results and progress exactly like `startScan`. No photo library
  permission required — the user picks items directly.
- **`NsfwDetector.scanFile(String filePath)`** — classifies a single image/video from a
  file path. Useful for scanning files from the app sandbox, document picker, etc.
- **`NsfwDetector.scanBytes(Uint8List bytes)`** — classifies a single image supplied as raw
  bytes (`Uint8List`). Useful when the image is already in memory (camera capture, network
  download, clipboard, etc.).
- Both `scanFile` and `scanBytes` accept an optional `modelId` and `confidenceThreshold` and
  return a `ScanResult` directly (no session required).

---

## 1.1.5

### Breaking changes

- Removed `BodyPartDetection`, `BoundingBox`, `NsfwSeverity`, `DetectionSummary` — these
  types were never backed by a running model and always returned empty/null results.
- Removed `ScanResult.detections`, `hasDetections`, `isDetectorResult`, `detectionSummary`.

---

## 1.1.4

### Docs

- Removed body part detection section from README and CHANGELOG — feature was never implemented.

---

## 1.1.3

### Fixes

- `CoreMLEngine.classifyBatch`: removed invalid `override` keyword (protocol conformance, not subclass override)
- `PixelBufferFeatureProvider`: changed from `struct` to `final class NSObject` — `MLFeatureProvider` is an ObjC protocol requiring a class
- `MLModel.predictions(from:)`: added required `options: MLPredictionOptions()` parameter (iOS 16+ SDK)
- `performBackgroundGalleryScan`: replaced internal `ModelIds.falconsai` default with string literal (public API constraint)

---

## 1.1.2

### Improvements

- **Auto model download in `startScan`** — `startScan` now automatically downloads and
  compiles the model if it is not yet on disk. Calling `downloadModel` + `preloadModel`
  from Dart before `startScan` is no longer needed (they still work for manual preloading).
  All three steps run on native background threads; `startScan` returns to Dart immediately.
- **`NsfwDetectIosPlugin.performBackgroundGalleryScan`** — new public static method for
  running a gallery scan from a `BGProcessingTask` or similar context where no Flutter
  engine is present. Events are silently discarded; the completion callback is called when
  the scan finishes.

---

## 1.1.1

### Fixes

- Fixed `podspec` version (was still `1.0.0`) and removed placeholder author/homepage fields.
- Removed placeholder `repository` URL from `pubspec.yaml`.

---

## 1.1.0

### Performance

- **CoreML batch inference** — images are now submitted to the model in batches via
  `MLModel.predictions(from:)`, reducing ANE/GPU setup overhead from N times to once
  per batch. Typical throughput improvement: **1.5–3× faster** on large photo libraries.
  Videos and Live Photos are unaffected; their pipeline is unchanged.
- Batch size is derived from the existing `concurrency` parameter — no Dart API change needed.
- Automatic fallback: if batch prediction fails twice in a row, the engine transparently
  reverts to the previous per-image Vision path for the remainder of the session.
- Added `ScanConfiguration.disableBatchPrediction` (default `false`) — set to `true` to
  force the serial Vision path, e.g. for diagnosing device-specific behaviour.

---

## 1.0.0

Initial release.

### Core API
- `NsfwDetector.instance` singleton for all plugin operations
- `startScan(ScanConfiguration)` → `ScanSession` with streaming results, progress, and completion
- `ScanSession.results` — `Stream<ScanResult>` emitting results as each asset is classified
- `ScanSession.progress` — `Stream<ScanProgress>` with scanned/total counts and fraction
- `ScanSession.done` — `Future<ScanSummary>` resolving on completion or cancellation
- `ScanSession.cancel()` — graceful abort at any point
- `scanAsset(localIdentifier)` — single-asset synchronous-style scan
- `requestPermission()` / `checkPermission()` — photo library permission handling
- `ScanConfiguration` — immutable config: threshold, concurrency, video settings, model selection

### Classification
- Five categories: `safe`, `suggestive`, `nudity`, `explicitNudity`, `unknown`
- `ScanResult.isNsfw`, `topCategory`, `topConfidence`, `confidenceFor(category)`
- `ScanResult.labels` — all categories sorted by confidence

### Models
- **OpenNSFW2** (CoreML, bundled, ~11 MB) — no download needed
- **Falconsai NSFW** and **AdamCodd NSFW** — downloadable via `downloadModel()`
- `availableModels()`, `preloadModel()`, `downloadModel()`, `deleteModel()`, `setModelUrl()`

### Widgets
- `NsfwGalleryView` — drop-in gallery with live scan, result badges, and custom tile/thumbnail builders
- `NsfwResultBadge` — 4 badge styles: `compact`, `detailed`, `iconOnly`, `minimal`
- `NsfwScanProgressBar` — 3 display styles: `linear`, `compact`, `textOnly`
- `NsfwGalleryTheme` — full color + style customization with `copyWith`
- `NsfwScanControls` — start/stop control bar
- `NsfwMediaTile` — composable tile widget for custom layouts

### Platform support
- **iOS 16+** — CoreML + Vision + Apple Neural Engine acceleration
- **Android API 24+** — TensorFlow Lite inference, tiered permission handling (API 21 → 33+)

### Video scanning
- Uniform temporal frame sampling
- Hard-threshold fast-exit (score > 0.9 → immediate flag)
- Center-weighted aggregation to reduce title-card false positives
- Configurable `maxVideoFrames` and `videoFrameInterval`
