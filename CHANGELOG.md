## 2.6.0 — 2026-05-22

> Adds a **web platform** so the one-shot scan APIs run in the browser. Additive only — existing iOS/Android app code is unchanged.

### Added

- **Web support — one-shot scanning in the browser.** The plugin now declares a `web` platform (`NsfwDetectWeb`). Supported APIs: `scanBytes` / `scanImageBytes`, `scanFile` / `scanFilePath` (a `blob:`/`http(s):` URL), and `pickMedia` (HTML `<input type=file>`). Classification runs on **nsfwjs** (TensorFlow.js); detection-mode (`ScanMode.detection` / `scanBytesDetectThenClassify`) runs the **NudeNet** ONNX graph via **onnxruntime-web**.
- **`NsfwWebConfig`** — runtime configuration for the web platform. The JS runtimes (TensorFlow.js, nsfwjs, onnxruntime-web) are loaded on demand from a public CDN by default; override `tfjsScriptUrl` / `nsfwjsScriptUrl` / `ortScriptUrl` (and `nsfwjsModelUrl`) to pin or self-host them. **`nudeNetModelUrl` must be set** before any detection-mode scan — there is no universal CDN copy of the NudeNet model; detection scans throw a clear `StateError` until it points at a CORS-reachable `.onnx` file.

### Notes / limitations (web)

- **Not available on web:** photo-library scanning (`startScan`, `scanSingleAsset`), camera scanning (`startCameraScan`), and background sweep — there is no browser equivalent. These throw `UnimplementedError` with a descriptive message.
- **Taxonomy:** nsfwjs has no separate "exposed-but-not-explicit" class, so the web classifier never reports `NsfwCategory.nudity` — explicit content collapses into `NsfwCategory.explicitNudity`. Web confidence scores are **not** numerically comparable to the native OpenNSFW2 classifier.
- **`roi` cropping is ignored on web** (permitted by the platform-interface contract).
- To run the example app on web, generate the web scaffold once with `flutter create --platforms web .` in `example/`.

### CI

- Golden widget tests are tagged `golden` and excluded from the Linux CI run (`flutter test --exclude-tags golden`) — goldens are rasterized on macOS and font rendering differs across hosts. Regenerate/verify them locally with `flutter test test/widgets/golden_test.dart`.

## 2.5.3 — 2026-05-22

> Documentation refresh plus a round of video- and camera-scan correctness fixes. `README.md` and the `doc/` guides are brought up to date with the 2.4.0 and 2.5.x feature set.

### Fixed

- **Video scan — confidently-safe frame no longer short-circuits the result.** `VideoResultAggregator`'s hard-threshold fast path returned the first frame whose *top label* exceeded 0.9 — regardless of category. A single frame classified ≥ 0.9 as `safe` would therefore mark the whole video safe, even when later frames were NSFW (false negative). The fast path now only fires for unsafe top labels, excluding the `safe` and `unknown` categories. Fixed on both iOS (`VideoResultAggregator.swift`) and Android (`VideoResultAggregator.kt`).
- **Video scan — iOS and Android now produce the same aggregated verdict.** The borderline-content weighted average diverged between platforms: iOS used a linear edge-to-center blend, Android a Gaussian. The same video could therefore be labelled differently per platform. iOS `VideoResultAggregator` was ported to the Gaussian weighting, so both platforms agree.
- **Video scan — short detections no longer diluted toward zero.** The weighted average divided each category's score by the *total* frame weight, even for categories that appeared in only a few frames — so a brief NSFW detection was averaged down against frames that never saw it. Each category is now normalised against the summed weight of the frames it actually appeared in (iOS + Android).
- **Video scan — perceptual dedupe is order-correct.** `VideoFrameSampler` compared each frame's dHash against the *last processed* frame, but `generateCGImagesAsynchronously` does not deliver callbacks in time order — so dedupe could compare non-adjacent frames and drop/keep them inconsistently. Frames are now sorted by requested time before adjacent hashes are compared. Image decode and ROI crop also moved out of the accumulator lock so frames decode concurrently.
- **iOS camera — frame pixel buffer is no longer used after free.** `CameraFrameProcessor` handed only the `CVPixelBuffer` from `CMSampleBufferGetImageBuffer` to the detached inference task. That reference is *unowned* — once the `CMSampleBuffer` was released, the capture output's pool could recycle the backing `IOSurface` mid-inference (corrupt frames / crash, worsened by `alwaysDiscardsLateVideoFrames`). The task now retains the whole `CMSampleBuffer` for the duration of the inference.
- **iOS camera — session recovers after interruption.** `CameraSessionTask` registered no observers for `AVCaptureSession` interruption / runtime errors. A phone call, Control Center, or another app taking the camera left the preview frozen because nothing called `startRunning()` again. Observers for `wasInterrupted` / `interruptionEnded` / `runtimeError` are now registered; the session restarts on `interruptionEnded` and after recoverable runtime errors.
- **iOS camera — start/stop race no longer leaves a stale preview.** A `stopCameraScan` arriving while `startCameraScan` was still awaiting permission/configuration could publish the session to the preview registry *after* stop had torn it down — preview attached to a dead session. `stop()` now marks the task stopped synchronously before any `await`, and `start()` re-checks that flag before publishing.
- **Android camera — concurrent `startCameraScan` rejected with `CAMERA_BUSY`.** Android had no single-session guard (iOS already had one): a second `startCameraScan`, or a delayed permission callback, could overwrite the live `CameraSessionTask`. A start is now rejected with `CAMERA_BUSY` while one is pending or running, and a `stopCameraScan` during the permission prompt cancels the not-yet-created session instead of letting a stale callback start it.
- **Android camera — preview surface detached on dispose.** `NsfwCameraPreviewView.dispose()` had an empty `try` block, so the `Preview` use case kept its `surfaceProvider` bound to a destroyed `PlatformView` — CameraX rendered into a dead surface and leaked the `SurfaceTexture`. `dispose()` and `onPreviewChanged(null)` now call `Preview.setSurfaceProvider(null)` on the previously bound use case.
- **Android camera — provider acquisition no longer blocks the main thread.** `CameraSessionTask` called the blocking `ProcessCameraProvider.getInstance(...).get()` inside a `withContext(Dispatchers.Main)` block, stalling the UI thread (ANR risk) while CameraX initialised. The blocking `get()` now runs on `Dispatchers.IO`; only `bindToLifecycle` stays on Main.
- **Android camera — IO scope cancelled on stop.** `CameraSessionTask.stop()` set a `stopped` flag but never cancelled its `ioScope`, leaving the start coroutine and the FPS-poll loop running past teardown. `stop()` now cancels the scope; a cancelled start is no longer reported as a camera error.
- **iOS camera — no frame events after stop.** A camera inference still running when `CameraFrameProcessor.drainInflight` timed out would emit its result / trigger an upload against the torn-down session and event sink. The processor now carries a stopped flag set by `CameraSessionTask.stop()`; an inference that finishes after stop skips emit and upload.
- **iOS camera — preview view deinit cleanup removed (was dead code).** `NsfwCameraPreviewView.deinit` spawned a `Task { @MainActor [weak self] }` whose body could never run — `self` is already gone once the task fires. The (now confirmed unnecessary) cleanup was removed: `CameraPreviewRegistry` holds observers weakly and prunes them, and ARC releases the preview layer's session.

### Docs

- **`README.md`** — install constraint bumped to `^2.5.3`; "What's new" now spans 2.3 → 2.5; new patterns documented (per-category thresholds, decision store, detect-then-classify, telemetry hooks, localization); `ScanResult.userDecision` added to the result-shape reference; privacy section clarifies that `onTelemetryEvent` is a local callback, not network telemetry.
- **`doc/` guides** — updated for the 2.4.0 / 2.5.x APIs.

## 2.5.2 — 2026-05-22

> iOS build hotfix plus a small accessibility / localization polish pass. 2.5.1 does not compile against the iOS toolchain — this release restores a clean build. Additive only; existing app code keeps working unchanged.

### Fixed

- **iOS — `CoreMLEngine.swift` compile error.** `_findModelURL(...)` is a `static` function but referenced the instance property `descriptor` (`descriptor.customAssetPath`), which Swift rejects with *"Instance member 'descriptor' cannot be used on type 'CoreMLEngine'"*. The custom-asset path is now threaded in as an explicit `customAssetPath: String?` parameter: the instance caller (`findModelURL`) passes `descriptor.customAssetPath`; static callers, including `CoreMLDetectorEngine`, can pass the registered custom path when one exists.
- **iOS — custom registered CoreML models load correctly.** `registerModel` stores custom artefacts in `customAssetPath` without a bundled resource name; the classifier and detector engines now accept that shape and resolve the exact registered `.mlmodelc` / `.mlmodel` path instead of failing early with `modelNotFound`.
- **iOS camera — start/stop lifecycle race closed.** A `stopCameraScan` arriving while `startCameraScan` is still awaiting permission/configuration now marks the session as stopped before the capture queue starts running, preventing an orphaned `AVCaptureSession` from staying alive after Dart has already requested stop.
- **`shared_preferences` lower bound corrected.** `SharedPreferencesDecisionStore` uses `SharedPreferencesAsync`, which was only added in `shared_preferences` 2.3.0. The dependency constraint was `^2.2.0`, so a lower-bound resolution picked a version without that API. Bumped to `^2.3.0`.
- **Badge contrast — WCAG AA.** `NsfwResultBadge` rendered its label / icons in hard-coded white; on the green (`safe`), orange (`suggestive`) and grey (`pending`) badge fills that falls below the 4.5:1 AA threshold. Foreground is now picked per fill colour via the new `NsfwGalleryTheme` contrast helpers — brand colours are unchanged.

### New

- **`NsfwGalleryTheme.contrastRatio` / `readableForeground` / `onCategoryColor`.** WCAG 2.1 contrast utilities. `readableForeground` returns the black/white foreground with the higher contrast against any opaque background — always ≥ 4.5:1.
- **Localizable widget button labels.** `NsfwLocalizations` gains eight getters (`buttonScanLibrary`, `buttonStopScan`, `buttonScanSettings`, `buttonRequestPermission`, `buttonOpenSettings`, `buttonResumeScan`, `buttonNewScan`, `buttonGrantAccess`), translated across all five bundled locales. `NsfwScanControls`, `NsfwPermissionsView` and `NsfwGalleryView` now read their button text from the active bundle instead of hard-coded English.

### Tooling

- **CI workflow** (`.github/workflows/ci.yml`) — runs `flutter analyze` + the full test suite on every PR, with a dedicated job wiring the eval-harness / false-positive-regression tests in as a gate.

### Notes

- Anyone stuck on 2.5.1 with `Instance member 'descriptor' cannot be used on type 'CoreMLEngine'` should upgrade to 2.5.2 — no source change is required in app code.

## 2.5.1 — 2026-05-21

> Accessibility pass over the four most-surfaced widgets. Every change is additive — sighted layouts and tap behaviour are unchanged; the screen-reader experience goes from "raw icons + percentage fragments" to a single coherent announcement per widget.

### Accessibility audit

- **`NsfwResultBadge`** — wrapped in a single `Semantics` node that announces `"NSFW: <category>"` with the percentage as the value (`"NSFW: Explicit Nudity" → "87%"`). Visual icon + text children sit under `ExcludeSemantics` so they don't double-announce. Pending / failed / skipped states get distinct labels. Category strings honour `NsfwLocalizations.current` from 2.5.0.
- **`NsfwMediaTile`** — Semantics node marks the tile as a `button` (when tappable), announces the media kind (`Photo` / `Video`), the category, and the confidence as the value (`"Photo, Nudity" → "91%"`). Selection state is exposed via the `selected` flag so a screen reader can read the multi-select context.
- **`NsfwCameraHud`** — top category pill is now a `liveRegion` Semantics node so screen readers re-announce when the live classification changes (`"NSFW live scan: Nudity" → "72%"`). The confidence progress bar gets a dedicated `"Live NSFW confidence"` label so it doesn't read as a generic progress widget.
- **`NsfwCameraView`** — root stack wrapped in a `Semantics(image: true)` node labelled `"NSFW live camera preview"`. Required because the camera surface itself is a PlatformView (UiKitView / AndroidView) whose contents are opaque to Flutter's accessibility tree.

### Tests

`test/a11y_semantics_test.dart` covers the four widgets with `tester.ensureSemantics()` + `getSemantics(...)` assertions — runs as part of the regular `flutter test` suite, no goldens, no native dependencies. Existing widget tests stay green.

### Out of scope

- Widget string overrides (button labels in `NsfwPermissionsView` / `NsfwGalleryView` / `NsfwScanControls`) — that's pure localization follow-up and belongs to the 2.5.x localization track, not a11y.
- Contrast audit against `NsfwGalleryTheme` extensions — design tokens are already tuned for WCAG AA at the default colour palette; a programmatic contrast checker against every theme variant is a follow-up.

## 2.5.0 — 2026-05-21

> First slice of the v2.5 "platform reach + polish" milestone. Ships **Localization** as the foundational piece — every subsequent v2.5.x release rides on this string-bundle contract. Source-level BC: every existing getter (`userMessage`, `displayName`, `confidenceDescription`, `ageRating`) keeps returning English regardless of the global override, so v2.4.x callers see zero behaviour change.

### New — Localization

- **`NsfwLocalizations` abstract bundle.** Plain-Dart interface (no `flutter_localizations` codegen, no `.arb` files, no new deps) carrying every user-facing string the plugin's non-widget helpers can produce: permission-status hints, NSFW category names, confidence buckets, and safety-profile age ratings. Why this shape: the i18n surface is small (≈20 strings), stable, and not bound to widget contexts — surfacing through a pluggable Dart class lets headless / log / Isolate callers get a localized string without booting `MaterialApp.localizationsDelegates`.
- **Bundled implementations:** `NsfwLocalizationsEn` (default), `NsfwLocalizationsDe`, `NsfwLocalizationsEs`, `NsfwLocalizationsFr`, `NsfwLocalizationsJa`. Hand-translated, BCP-47 tagged.
- **`NsfwLocalizations.current`** — app-wide static. Reassign once at startup (`NsfwLocalizations.current = const NsfwLocalizationsDe();`) for global override; reads are synchronous.
- **`NsfwLocalizations.resolve(tag)`** — picks a bundled impl by BCP-47 tag. Case-insensitive, region subtag is ignored (`de_DE` → German, `es-MX` → Spanish). Unknown / empty tags fall back to English.
- **`PhotoLibraryPermissionStatus.localizedMessage([locale])`** — defaults to `NsfwLocalizations.current`; pass an explicit bundle to override per call. The legacy `userMessage` getter still returns English.
- **`NsfwCategory.localizedName([locale])`** — same pattern; legacy `displayName` stays English.
- **`ScanResult.localizedConfidenceDescription([locale])`** — same pattern; legacy `confidenceDescription` stays English.
- **`NsfwSafetyProfile.localizedAgeRating([locale])`** — same pattern; legacy `ageRating` field stays English.

### Override hook for additional languages

Host apps that need a language outside the bundled five subclass `NsfwLocalizations`, fill in the abstract getters, and install at startup:

```dart
class NsfwLocalizationsPtBr extends NsfwLocalizations {
  const NsfwLocalizationsPtBr();
  @override String get languageCode => 'pt-BR';
  @override String get permissionAuthorized => 'Acesso total à biblioteca';
  // … the remaining 19 strings
}

void main() {
  NsfwLocalizations.current = const NsfwLocalizationsPtBr();
  runApp(const MyApp());
}
```

Widget-level string overrides (button labels, scaffold copy in
`NsfwPermissionsView` / `NsfwGalleryView` / `NsfwScanControls` / etc.)
are NOT covered by this release — they get a dedicated v2.5.x follow-up
so the diff stays reviewable.

## 2.4.0 — 2026-05-21

> Six v2.4 features plus a critical iOS-side download hotfix. Existing 2.3.x callers keep working unchanged; everything below is additive (or, in the case of the iOS hang, a transparent runtime fix).

### Fixes — iOS model download hang under iOS 17/18

- **`ModelDownloadManager` rewrite.** The iOS-15 async `URLSession.download(from:delegate:)` API silently hangs under iOS 17/18 when the session is built with a session-level `URLSessionDownloadDelegate` AND a per-task delegate is also passed: the awaited continuation never resumes, progress callbacks fire normally, but the download never finishes and no error is thrown. Replaced with the classic `downloadTask` + `withCheckedThrowingContinuation` pattern. Single-shot `completion` closure resolves the continuation from `didFinishDownloadingTo` (success) or `didCompleteWithError` (failure). Temp file is moved out of URLSession's slot *inside* the delegate callback so the staged URL stays valid for size / SHA-256 / extraction. URLSession callbacks pinned to a dedicated serial `OperationQueue` to avoid cooperative-pool deadlock. `withTaskCancellationHandler` wires Swift-task cancellation back into the URLSessionDownloadTask. **If you were on 2.3.0 and downloads silently froze on iOS 17/18 — this is the fix.**

### New — Per-category thresholds

- **`ScanConfiguration.thresholdsByCategory: Map<NsfwCategory, double>?`** — lets product code express "block explicit aggressively (0.5) but tolerate suggestive (0.95)" without re-classifying. `ScanResult.isNsfw` and the category shortcuts (`hasNudity` / `hasExplicitContent` / `isSuggestive`) walk each NSFW-priority label against its per-category threshold and fall back to the scalar `confidenceThreshold` for unmapped categories.
- **`ScanResult.thresholdsByCategory`** — propagates through `ScanSession` so per-asset events get evaluated under the configured policy, and through `ScanResult.toJson` / `fromJson` so persisted results re-evaluate consistently.
- **`ScanResult.withThresholds(...)`** — returns a copy with a new policy without re-running inference. Unknown category names are dropped and out-of-range values are clamped on parse so persisted maps stay forward-safe.

### New — Telemetry hooks

- **`NsfwDetector.onTelemetryEvent: TelemetryHandler?`** — single sink for structured events covering every scan / download / lifecycle transition. Carries timing, modelId, top-category, and a `0..9` confidence decile bucket so analytics rollups stay PII-free by default. `localId` only attaches when `NsfwDetector.includeLocalIdsInTelemetry = true`.
- **Event variants.** `scanStarted`, `scanCompleted` (per session result), `scanFinished`, `classifyTime` (one-shot scans), `modelLoaded` (preloadModel), `downloadStarted` / `downloadProgress` / `downloadFinished`, `cancelHonored`, `backgroundSweepChanged`. Handler runs inline with the scan pipeline — exceptions are swallowed so a buggy sink can never break scanning. Pipe through an Isolate / queue for heavyweight processing.

### New — Persistent scan-decisions store

- **`DecisionStore` subsystem** — moderator-override store keyed by `localIdentifier`. `ScanDecision.allow` forces `isNsfw=false`, `ScanDecision.block` forces `isNsfw=true`, regardless of what the classifier says. Decisions populate `ScanResult.userDecision` on every scan emitted by the detector.
- **`InMemoryDecisionStore`** — process-lifetime default, no native deps.
- **`SharedPreferencesDecisionStore`** — persistent across cold starts, serialises the full map as JSON so arbitrary `localId` strings (pipes, newlines, Unicode) round-trip safely. Adds `shared_preferences ^2.2.0` as a runtime dependency.
- **`NsfwDetector.decisions` + `useDecisionStore(...)`** — getter exposes the active store; setter swaps in a different backing impl and disposes the old one. Per-scan lookups read from an in-memory cache primed from the store and kept in sync via `store.changes`, so the sync path stays fast even when backed by async storage.
- **`ScanResult.withUserDecision(...)` + `userDecision` field** — applied automatically by `ScanSession` for library scans + `pickAndScan`, and by every one-shot scan (`scanAsset` / `scanFile` / `scanBytes` / `scanUrl` / `scanImageProvider`) when the platform-returned `localIdentifier` matches a stored entry. Camera live mode is intentionally not wired: frames lack a persistent identifier to key decisions to.

### New — Detect-then-classify pipeline

- **`ScanMode.detectThenClassify`** — new enum value (wire-stable `"detectThenClassify"`). Runs the body-part detector first, classifies every emitted crop with the NSFW classifier, attaches per-box labels to each `BodyPartDetection`. Strictly stronger signal than detector-only (graded confidence per region) and classifier-only (per-region attribution).
- **`BodyPartDetection.labels: List<NsfwLabel>?`** — optional, populated by the new pipeline. `null` for plain detection / classification runs.
- **`NsfwDetector.scanBytesDetectThenClassify(...)` + `scanFileDetectThenClassify(...)`** — public entry points. Implementation is Dart-side (1 detector call + N classifier calls per image; cropping via dart:ui) so the feature ships today without native engine changes; a native one-shot endpoint is a v2.5 optimisation.

### New — Evaluation harness + golden set

- **`tools/eval/`** — CLI + Dart library that runs labelled image datasets through `scanFile` and produces per-category precision / recall / F1 reports.
- **`lib/eval_metrics.dart`** — pure tallying with macro / weighted F1, confusion matrix, JSON + Markdown rendering.
- **`lib/eval_dataset.dart`** — JSON manifest reader. Malformed rows are skipped with a one-line reason.
- **`lib/eval_runner.dart`** — orchestrator with an injectable scan dispatcher (typedef `ScanByPath`) so the runner is testable against scripted results.
- **`bin/run.dart`** — `dart run tools/eval/bin/run.dart <dataset.json> --model <id> --out report.md`. `--format json` for machine-readable output.
- **`fixtures/smoke_dataset.json`** — tiny canonical fixture. Solid-colour PNGs that any classifier rounds as `safe`, so the harness machinery can be smoke-tested on every dev box without bundling real-world content.

### New — False-positive regression suite

- **`tools/eval/lib/fp_regression.dart`** — sub-bullet of the eval harness. `EvalItem.subcategory` (optional) tags each safe-set item with its edge-case bucket (`beach_photo`, `art_nude`, `baby_bath`, `anime`, …). `runFpRegression` filters to `truth == safe`, tallies false-positives per subcategory, produces `FpRegressionReport` with overall rate, per-bucket breakdown, capped example collection.
- **Baseline + tolerance support** — pass `{subcategory: baselineRate}` and a `tolerance` (default 5 pp); `report.exceeded` returns only the buckets that drifted above `baseline + tolerance` so CI can fail with a focused diagnostic instead of "metrics changed somewhere."

### Misc

- `NsfwScanSession` accepts an optional `telemetrySink` + `decisionLookup` in its constructor; both are wired automatically by `NsfwDetector.startScan` / `pickAndScan`.
- `pubspec.yaml`: adds `shared_preferences ^2.2.0` (runtime) and `shared_preferences_platform_interface ^2.4.0` (dev) for the DecisionStore tests' `InMemorySharedPreferencesAsync`.

## 2.3.0 — 2026-05-21

> Public-API extensions for image-provider scanning, URL scanning, cache lookup, native prefetch, and detection-aware redaction. All additive — existing 2.2.x code keeps working unchanged.

### New — Headless scan inputs

- **`NsfwDetector.scanImageProvider(ImageProvider, {confidenceThreshold, modelId, region, configuration})`** — scans any Flutter `ImageProvider` (`NetworkImage` / `MemoryImage` / `FileImage` / `AssetImage` / custom). Resolves the provider, encodes to PNG bytes once, then delegates to `scanBytes`. Gallery tiles, hero images, and chat bubbles can be gated without the caller writing their own resolve-and-encode dance.
- **`NsfwDetector.scanUrl(Uri, {headers, timeout, confidenceThreshold, modelId, region, maxBytes})`** — fetches a remote image over HTTP/HTTPS and scans the response body. Streams the body with a hard `maxBytes` cap (default 32 MB) so a malicious server can't OOM the caller. Rejects non-http(s) schemes via `ArgumentError`; surfaces non-2xx as `HttpException`; honours `Duration` timeout on connect + read.

### New — Cache lookup

- **`NsfwDetector.cachedResult(localIdentifier, {modelId, confidenceThreshold})`** — returns a previously-scanned result from the on-device SQLite cache without triggering a re-classification. `null` on miss. Returned `ScanResult` carries `fromCache = true`.
- **`NsfwDetector.cacheUpdates`** (stream) — `Stream<ScanResult>` derived from the existing native scan event channel, filtered to per-asset result events. Apps can subscribe once to keep gallery badges in sync without polling the cache.

### New — Asset prefetch

- **`NsfwDetector.prefetchAssets(List<String> localIdentifiers, {modelId})`** — pre-warms the native asset cache so subsequent `scanAsset` / `startScan` calls hit warm I/O. iOS seeds `PHCachingImageManager`; Android touches the underlying URI input stream to warm the OS page cache. Best-effort; safe to call with hundreds of ids.

### New — Detection-aware redaction

- **`NsfwDetector.redactBytes(Uint8List bytes, ScanResult result, {mode, intensity, outputFormat})`** — returns a redacted copy of `bytes`. When `result.detections` is non-empty, only the per-detection bounding boxes are redacted; otherwise the whole image is redacted (classifier-only fallback). `intensity` clamped to `[0, 1]`. `outputFormat` defaults to `"jpeg"` (`"png"` available).
- **`NsfwDetector.redactFile(File input, ScanResult result, {outputFile, mode, intensity})`** — same, file in / file out. Writes to a sibling temp file when `outputFile` is null.
- **`RedactionMode`** — new enum: `blur` (default, CIGaussianBlur on iOS / approximate-gaussian downscale on Android), `pixelate` (mosaic), `blackBox` (solid fill).

### New — Background sweep

- **`NsfwDetector.scheduleBackgroundSweep(BackgroundSweepOptions)`** / **`cancelBackgroundSweep()`** — "moderate the library once a night while the user is asleep". Per-asset results land in the on-device `ScanCache`; foreground apps read them via `cachedResult` / `cacheUpdates` on next launch.
- **`BackgroundSweepOptions`** — value type bundling `interval` (≥ 15 min, WorkManager's hard floor), `requiresCharging`, `requiresWifi`, and the `ScanConfiguration` the worker dispatches.
- **iOS dispatcher (`BackgroundSweepScheduler`)** — wraps `BGTaskScheduler`. The plugin registers its launch handler inside `register(with:)` (which runs during `application(_:didFinishLaunchingWithOptions:)`, the legal window for BG-task identifier registration). Apps that haven't opted in via `Info.plist > BGTaskSchedulerPermittedIdentifiers` pay nothing; `scheduleBackgroundSweep` raises `HOST_APP_NOT_CONFIGURED` so the Dart side gets a typed signal.
- **Android dispatcher (`NsfwSweepWorker`)** — `CoroutineWorker` enqueued via `WorkManager.enqueueUniquePeriodicWork` with constraints (`setRequiresCharging`, `setRequiresBatteryNotLow`, `NetworkType.UNMETERED` when `requiresWifi: true`). Cancellation propagates through the worker coroutine into the underlying `scanJob`.
- **Host-app integration.** iOS apps add `com.nsfw_detect.background_sweep` to `BGTaskSchedulerPermittedIdentifiers`. Android apps don't need manifest changes — `androidx.work:work-runtime-ktx 2.9.1` is now a plugin dependency.
- **`ScanSessionTask.awaitCompletion`** (Android, internal) — public-suspending wrapper around the internal `scanJob.join()` so the worker's `doWork()` can stay alive until the session reports done.

### New — Multi-model ensemble voting

- **`EnsembleStrategy`** — new sealed base + `MajorityEnsemble` / `WeightedEnsemble`. Apps that want to combine open_nsfw_2, AdamCodd, and Falconsai (or any registered classifier set) on borderline samples can now do so with two lines of config.
- **`MajorityEnsemble({modelIds, borderlineMin = 0.45, borderlineMax = 0.55})`** — each model votes for its top category; models whose top confidence lands inside the borderline band **abstain** rather than dragging the consensus the wrong way. Ties resolve to the highest-confidence raw result.
- **`WeightedEnsemble({modelIds, weights})`** — per-category confidence-weighted average. Missing weights default to 1.0; negative weights are rejected.
- **`NsfwDetector.scanBytesEnsemble` / `scanFileEnsemble` / `scanAssetEnsemble`** — fan an input out to every modelId in the strategy, then combine via the strategy. Inference cost scales linearly with the model count; default is OFF — only enable when the false-positive reduction is worth the 2-3× latency.
- **Classifier-only.** Passing a detector model id throws `ArgumentError` after the first per-model scan returns spatial detections — detector outputs aren't meaningfully averageable without further design.

### New — Runtime custom model registration

- **`NsfwDetector.registerModel(ModelRegistration)`** — plug your own `.mlmodelc` (iOS) or `.tflite` (Android) artefact into the plugin without forking. Registrations live for the process lifetime; re-register on cold start.
- **`ModelRegistration`** — value type carrying `id`, `displayName`, `assetPath`, `inputSize`, `kind` (classifier / detector), optional `downloadUrl`, `classLabels`, `version`, `metadata`.
- **`ModelKind`** — new enum: `classifier` (default) / `detector`. Routes the registered model to the right native engine factory (CoreMLEngine / CoreMLDetectorEngine on iOS; TFLiteEngine / TFLiteDetectorEngine on Android).
- **Path sandboxing.** The native side resolves `assetPath` against the host app's writable directories — iOS Application Support / Documents / Caches / tmp; Android `filesDir` / `cacheDir` / `dataDir` / `noBackupFilesDir`. Paths outside the sandbox are rejected with `INVALID_PATH`. Missing artefacts surface `MODEL_NOT_FOUND`.
- **`ModelDescriptorNative.customAssetPath`** (native) — both engines load directly from the custom path when set, bypassing the bundle / download search. TFLite magic-byte validation (`TFL3`) still runs.

### New — Per-asset skip

- **`NsfwDetector.skipCurrentAsset()`** — best-effort fire-and-forget that signals the active scan to skip the next asset entering its loop. Multiple rapid calls collapse to a single skip. Use [cancelScan] to abandon the whole session instead. Emits an explicit `ScanStatus.skipped` result so subscribers see the event. No effect when no scan is running.

### New — Profile / batch / dedupe helpers

- **`NsfwSafetyProfile.evaluate(ScanResult)` / `evaluateAll(Iterable<ScanResult>)`** — bool helper that asks "would this result be flagged at this profile's threshold?". `safe` / `unknown` categories pass regardless of confidence; NSFW categories must score below `recommendedThreshold`. `failed` / `skipped` results route to manual review (return false).
- **`NsfwDetector.scanPaths(Iterable<String>)`** — single batch entry point that auto-routes by prefix: `file://` → `scanFile`, `http(s)://` → `scanUrl`, `data:` → base64-decoded `scanBytes`, anything else → `scanAsset`. Per-item failures surface as `ScanResult.failed` so the batch always completes. Optional `onProgress(done, total)`.
- **`NsfwDetector.findDuplicates(Iterable<MediaItem>, {loadBytes, maxHammingDistance = 5})`** — groups perceptually-identical items into clusters via dHash. Caller supplies `loadBytes` so the detector decouples from any specific storage layer. Singletons are dropped; only clusters of two or more are returned.
- **`PerceptualHash.toJson()` / `PerceptualHash.fromJson(String)`** — JSON-friendly round-trip for persisting hashes alongside `MediaItem.localIdentifier`. `PerceptualHash.fromBytes(bytes)` alias added for symmetry with `BodyPartDetection.fromBytes`-style factories.

### Fixes — code-review hardening

- **iOS** `ImageAnalyzer`: PhotoKit fetches gated by 30 s wall-clock timeout + `OSAllocatedUnfairLock<Bool>` resume-once across both `requestImage` / `requestImageDataAndOrientation` callbacks. No more hanging scans for iCloud-offline assets and no double-resume races if PhotoKit ever delivers multiple callbacks.
- **iOS** `ScanSessionTask`: explicit `Task.checkCancellation()` before the video sampler — cancelled scans no longer burn CPU on frame extraction.
- **iOS** `ScanMethodHandler`: `loadFileRepresentation` continuation wrapped in a task-group timeout + resume-once lock. Picker flow can't deadlock on iCloud-only items.
- **iOS** `ScanEventSink.emit`: reads the current sink under the lock inside `main.async` instead of a stale capture, closing the listen → cancel → re-listen race that could invoke a dead sink.
- **iOS** `ZipExtractor`: `readExact` now distinguishes "EOF at start" (returns nil) from "EOF mid-record" (throws `ZipError.truncated`). Replaces the prior `nil : nil` tautology that silently accepted truncated archives.
- **Android** `TFLiteEngine` / `TFLiteDetectorEngine`: full inference pipeline (resize + buffer fill + `interpreter.run`) now lives inside `runMutex.withLock` with leak-safe scaled-bitmap recycle. Closes the concurrent-resize Bitmap leak and the not-thread-safe interpreter race.
- **Android** `AIUCordinator`: bounded OkHttp timeouts (connect 10 s, write / read 30 s, call 60 s) replace the 0-ms infinite defaults that pinned worker threads on flaky cellular.
- **Android** `ScanCheckpoint`: dirty-flag short-circuits no-op `serialise + writeText` passes; write failures restore the flag so the next opportunity retries.
- **Android** `ScanSessionTask.cancel()`: now also cancels scope children so a future child coroutine outside `runScan` can't survive the host Activity.
- **Android** `MediaPermission`: `READ_MEDIA_VIDEO` added to the API 33+ request set and status resolution. Closes the silently-zero-videos gap on Android 13/14.
- **Dart** `NsfwDetector._resolveThreshold`: `assert` replaced with `ArgumentError.value` so out-of-range thresholds throw in release-mode too.
- **Dart** `NsfwInitOptions.defaultThreshold`: aligned from `0.7` to `0.75` across all four constructors to match the docs and migration-guide examples.
- **Dart** `ModelDownloadProgress`: `==` / `hashCode` added — `@immutable` value type now behaves correctly in `Set` / `Map`.

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

### New — Region-of-Interest scans

- **`ScanRegion`** — normalized `[0..1]` `{x, y, width, height}` value type with `ScanRegion.full()`, `copyWith`, JSON round-trip, and asserts on out-of-range coords.
- Optional `ScanRegion? region` parameter on `scanFile`, `scanBytes`, `scanAsset`, `isNsfwFile`, `isNsfwBytes`, `isNsfwAsset`, plus `ScanConfiguration.region` / `CameraConfiguration.region` for library and live-camera scans. Crop is applied natively before model input — iOS via `CIImage.cropped(to:)` with pool reuse, Android via `Bitmap.createBitmap(...)` with leak-safe recycle. Useful for "scan faces only" or "ignore watermark" workflows.

### New — Safety profiles

- **`NsfwSafetyProfile.kidSafe` / `.teen` / `.adult`** — three age-rating-aligned presets that bundle a recommended threshold and an `ageRating` string. `toScanConfiguration({...overrides})` / `toCameraConfiguration({...overrides})` translate them to a config in one line.

### New — Perceptual-hash duplicate cache

- **`PerceptualCache`** (`NsfwDetector.instance.perceptualCache`) — opt-in, dependency-free 8×8 dHash + LRU. `lookup(bytes, maxDistance: 5)` returns a prior `ScanResult` for visually identical bytes; `remember(bytes, result)` populates the cache. Useful as a pre-check before `scanBytes` in chat/forwards scenarios. Pure Dart — no native or pubspec deps.

### New — `NsfwResultRedactor` widget

- Wraps a child image and applies per-detection or full-image blur/solid overlays at the regions produced by `ScanMode.detection`. Constructors: `.bytes()`, `.file()`, `.asset()`. Customisable `blurSigma`, `overlayColor`, optional `badge` slot — defaults to the existing `NsfwResultBadge`.

### New — Allow- / denylist on library scans

- `ScanConfiguration.skipAssetIds` / `includeOnlyAssetIds` (`Set<String>`) — short-circuit per-asset filtering. `includeOnlyAssetIds` wins when both are set. Applied natively where supported and as a defensive Dart-side filter in `ScanSession` regardless.

### New — Progress ETA & throughput

- `ScanProgress.itemsPerSecond` and `ScanProgress.estimatedRemaining` (`Duration?`) — computed from a rolling 20-event throughput window inside `ScanSession`. Drives "≈ 4m 12s remaining" copy without app-side bookkeeping.

### New — On-device threshold calibration

- **`NsfwDetector.calibrate({samples, precisionTarget})`** — feed labelled `(bytes, expectedNsfw)` samples, sweep thresholds in 0.05 steps, return the smallest threshold whose precision meets `precisionTarget` (default 0.9). Pure Dart, no native dependency.

### New — `NsfwInitOptions.production()` preset

- Companion to `.debug()` / `.lazy()`. Defaults: native logging off, preloads `openNsfw2`, `defaultThreshold: 0.7`, no auto-download. Each preset now documents its intended use case in dartdoc.

### New — Platform load awareness

- **iOS**: `ProcessInfo.processInfo.isLowPowerModeEnabled` and `.thermalState` are monitored; concurrency and camera FPS scale by `1.0 / 0.5 / 0.25` for `nominal / serious / critical` (and half again when low-power is on). Implemented in `DeviceLoadMonitor.swift`; scan and camera tasks both consult the same live load factor.
- **Android**: `PowerManager.OnThermalStatusChangedListener` (API 29+) and `PowerManager.isPowerSaveMode` produce the same backoff curve. `BatteryManager.BATTERY_PROPERTY_CAPACITY < 20%` triggers the low-power halving on older devices.

### New — Native delegate transparency

- **iOS**: `os_log` category `NSFW.CoreML` records requested vs. resolved `MLComputeUnits`. New method-channel call `getComputeUnits(modelId)` returns the engine's actual setting.
- **Android**: `TFLiteEngine` and `TFLiteDetectorEngine` set `actualLoadedDelegate = "cpu"` and emit a structured `Log.w("NSFW-TFLite", …, throwable)` on delegate fallback. New `getDelegateInfo(modelId)` method-channel call surfaces the active delegate for in-app diagnostics.

### New — Generic frame-stream scanner

- **`FrameStreamScanner`** (`NsfwDetector.instance.scanFrameStream({frames, targetFps, …})`) — feed any `Stream<Uint8List>` of frame bytes, get a throttled, backpressure-safe `Stream<ScanResult>`. Drops frames that arrive faster than `targetFps` and silently drops new frames while a scan is still in flight (no unbounded queueing). Optional `dedupeCache: PerceptualCache` replays prior results for visually identical frames. `waitForNsfw({Duration? timeout})` convenience helper. Dartdoc includes a `flutter_webrtc` integration snippet — no hard dependency on any specific frame source.

### New — Animated GIF / WebP / APNG

- iOS: `AnimatedImageSampler` (`CGImageSourceGetCount` + GIF/APNG metadata sniffing) extracts up to 8 evenly-spaced frames, applies ROI via `RoiCropper`, classifies each via the existing pipeline, aggregates with the Gaussian center-bias `VideoResultAggregator`. Defensive fallback to single-frame decode on malformed sources.
- Android: GIFs use `android.graphics.Movie` + canvas rasterization at evenly-spaced `setTime(ms)` points — real multi-frame extraction. Animated WebP / HEIF currently ship a single-frame fallback (AOSP `ImageDecoder` does not expose per-frame access without a third-party demuxer; documented in code).
- Result map carries `frameCount: Int` and `animated: true` so debug UI can surface "Scanned N frames" for animated content.

### New — RAW formats

- iOS: `RawImageDecoder` accepts 13 extensions (dng, cr2/cr3, nef, arw/srf/sr2, raf, rw2, orf, srw, nrw). iOS 15+ uses `CIRAWFilter` with default RAW settings; older OS falls back to `CGImageSourceCreateThumbnailAtIndex` (the embedded JPEG preview, typically 1080p+ in modern cameras — good enough for classification). Reliability matrix per format in the source comments.
- Android: native DNG decode via `BitmapFactory` on Android 12+. Vendor RAW (CR2/NEF/ARW/RAF/RW2/etc) falls back to `ExifInterface.thumbnailBytes` — the embedded JPEG preview. If neither path produces bytes, the scan errors with `RAW_FORMAT_NO_PREVIEW` so apps can surface specific guidance.

### New — Live Photo motion classification (iOS)

- `LivePhotoSampler` detects `PHAsset.mediaSubtypes.contains(.photoLive)`, streams the `.pairedVideo` `PHAssetResource` to a temp `.mov`, then uses `AVAssetImageGenerator` to sample up to 3 frames. Still image + sampled video frames are aggregated together — Live Photos with safe stills but explicit motion now classify correctly. `livePhoto: true` plus `livePhotoMotionSampled: true` flags surface in the result map; the latter is only `true` when the paired video actually decoded (iCloud-only assets / trimmed motion gracefully fall back to still-only).
- Android: no platform concept of Live Photos. Documented as iOS-only — Samsung Motion Photos decode as static images; apps that need Motion Photo video scanning must extract the `.mp4` and call `scanFile()` on it manually.

### New — Crop-resistant perceptual hash

- **`BlockPerceptualHash`** — 4×4 grid of per-block 8×8 dHashes (16 hashes per image). Compares via per-block Hamming distance with configurable `minMatchingBlocks` (default 6 of 16) and `blockTolerance` (default 8 bits per block) — matches images even after crops that remove ≤ 60% of the source.
- **`CropResistantCache`** (`NsfwDetector.instance.cropResistantCache`) — LRU keyed by `BlockPerceptualHash` with `lookup(bytes)` / `remember(bytes, result)`. 16× slower than `PerceptualCache` per lookup, but matches re-uploads that escape simple pHash (e.g., forwarded screenshots with new framing).

### New — `@NsfwModel` codegen

- **`@NsfwModel`** annotation in the main package (`id`, `defaultThreshold`, `defaultMode`, `displayName`, `tags`). Pure metadata — no runtime behaviour.
- Companion **`nsfw_detect_gen`** package (under `gen/nsfw_detect_gen/`) — `source_gen` + `build_runner` generator that emits a typed `_$<Class>Registry`, a `models: Map<String, NsfwModel>` literal, and a `registerAll(NsfwDetector)` helper for any class annotated with one or more `@NsfwModel(...)` static-const fields. Opt-in as a `dev_dependency`; the main package gains no new deps. Example pre-generated `.g.dart` ships in `gen/nsfw_detect_gen/example/`.

### New — Widget

- **`NsfwModerationGate`** — drop-in widget that scans a source (`.bytes(...)` / `.file(...)` / `.asset(...)`), renders the child on safe, and blurs + overlays a warning on NSFW. Custom `nsfwBuilder`, `errorBuilder`, and `loading` slots for app-specific UI. Fails open by default (renders child on scan error); override `errorBuilder` to fail closed.

### Fixed

- **Android Bitmap leak** in `ScanSessionTask` — every decoded bitmap is now recycled in a `finally` via `BitmapPipeline`, which also routes EXIF rotation, ROI cropping, and source-stream close in one place. Eliminates multi-GB transient allocations on large library scans.
- **Android EXIF rotation** — `BitmapPipeline` reads `ExifInterface` orientation and applies `Matrix.postRotate` so 90°/180°/270°-rotated photos classify correctly. Adds `androidx.exifinterface:exifinterface:1.3.7` to `android/build.gradle`.
- **Android checkpoint resume** — new `ScanCheckpoint` persists `{sessionId, configHash, lastProcessedAssetId, processedCount, totalCount}` to `cacheDir/nsfw_detect/checkpoints/<configHash>.json`. Re-running the same `startScan` skips already-processed assets, matching the existing iOS behaviour. Configurable via `resumeFromCheckpoint` (default `true`).
- **Android video aggregation parity** — new `VideoResultAggregator` replaces the prior "first frame only" path with the same Gaussian center-bias weighting iOS already uses. Identical video → identical classification across platforms.
- **`downloadProgress` stream replay** — `NsfwDetector.downloadProgress` now caches the most-recent in-flight value per `modelId` and replays it on new subscribers. UI code that attaches a listener after `downloadModel(...)` no longer misses early-burst progress events.
- **Default-threshold drift** — `NsfwDetector` now captures the current default threshold into a local before any `await` and serialises against in-flight `init` / `reinit`. A scan started mid-`reinit` no longer silently flips to the new threshold partway through.
- **Threshold range validation** — `confidenceThreshold`, `detectionConfidenceThreshold`, and `iouThreshold` now assert `[0.0, 1.0]` in `ScanConfiguration`, `CameraConfiguration`, and on inline call sites.
- **`MediaItem` equality contract documented** — equality is by `localIdentifier` only (matches PHAsset / MediaStore semantics). New `MediaItem.equalsContent(other)` helper exposes structural comparison for callers that need it.

### Performance

- **iOS video-frame perceptual dedupe** — `VideoFrameSampler` computes an 8×8 dHash per sampled frame and skips frames within Hamming-distance ≤ 6 of the previously accepted frame. 30–50 % fewer inferences on keyframe-burst videos. Toggleable via the sampler's `enablePerceptualDedupe`.
- **iOS early-exit on high-confidence videos** — `ScanSessionTask.classifyFrames` finalises a video result as soon as a frame returns `topConfidence > 0.95` with a non-safe / non-unknown category. Gate on by default; method-channel arg `earlyExitOnHighConfidence` (Bool) for overrides.
- **CoreML batch inference auto-recovery** — `CoreMLEngine` previously disabled batch mode permanently after two failures. Now tracks `lastBatchFailureAt` and probes one trial batch after 5 minutes; success re-enables, failure resets the timer.
- **Camera FPS adapts live** — `CameraSessionTask` (both platforms) subscribes to `DeviceLoadMonitor` and re-throttles via `setTargetFps` on thermal / power-state changes without restart.

### DX / value-type ergonomics

- `PickedMedia`, `ScanSummary`, `ModelStateSnapshot`, `MediaItem`, `ScanProgress`, `ScanRegion` now all carry `copyWith`, `==`, `hashCode`, and `toString`. Asymmetry with `ScanConfiguration` removed.
- Re-export shims `lib/nsfw_detect_platform_interface.dart` and `lib/nsfw_detect_method_channel.dart` are now `@Deprecated` and slated for removal in 3.0. Import `package:nsfw_detect/nsfw_detect.dart` as the single public entry — the actual `NsfwPlatformInterface` lives at `lib/src/platform/`.

### Pub.dev / project hygiene

- Topics tightened to the strongest five for pub.dev cap: `content-moderation`, `nsfw-detection`, `camera`, `video-scanning`, `permission-handling`.
- `pubspec.yaml` declares `funding:` (GitHub Sponsors) and a `screenshots:` block (PNGs to be added under `example/assets/screenshots/` before publish).
- `analysis_options.yaml` enables `unawaited_futures`, `prefer_const_constructors[_in_immutables]`, `prefer_const_declarations`, `prefer_const_literals_to_create_immutables`, `prefer_final_locals`, `avoid_empty_else`, `sort_child_properties_last`, `use_super_parameters`, `unnecessary_lambdas`; promotes `unused_import` / `dead_code` / `missing_required_param` to errors.

### Testing

- 18 golden snapshots for `NsfwResultBadge`, `NsfwScanProgressBar`, `NsfwSkeletonTile`, `NsfwSelectionToolbar` across `NsfwTheme.light()` / `.dark()`.
- New `test/_fakes/fake_nsfw_detector.dart` + companion test demonstrating the downstream `FakeNsfwPlatform` recipe so apps depending on this plugin can unit-test without booting the platform channel.
- `example/integration_test/plugin_integration_test.dart` extended from 2 to 6 tests: `init()` reporting, `scanBytes` happy-path, `scanFiles` batch progress, plus the existing permission + model-list smoke tests.

### Example app

- New screens: `moderation_gate_screen.dart` (the three constructors side-by-side, `nsfwBuilder` toggle), `models_screen.dart` (live download speed + ETA, status pills, preload/remove), `error_states_screen.dart` (permission denials, camera errors, model unavailable, offline-during-download), `detection_demo_screen.dart` (end-to-end `ScanMode.detection` with `NsfwDetectionOverlay`, IoU + detection-threshold sliders).
- Light / dark theme toggle backed by `MaterialApp.themeMode` and `SharedPreferences`.

### Docs

- README Quickstart now leads with `pickMedia` (no library permission), then `scanFile` / `scanBytes`, then `startScan`. `init`, presets, and `NsfwModerationGate` are documented up front.
- New guides:
  - `doc/platform-gotchas.md` — HEIC handling, iOS 17 Limited Library re-prompt, iOS Privacy Manifest sample, Android 13 Photo Picker, Android 14 partial access (`READ_MEDIA_VISUAL_USER_SELECTED`), ProGuard/R8 keep rules, minSdk matrix.
  - `doc/migration-2.1-to-2.2.md` — additive-only walkthrough with before/after for `init`, presets, batch APIs, `isNsfwFile`, `requestPermissionAndStartScan`, `NsfwModerationGate`, permission helpers.
  - `doc/false-positives-faq.md` — threshold guidance, illustrative FP-rate table (0.5 / 0.7 / 0.85), suggestive-vs-NSFW, camera flicker, escalation paths.
  - `doc/performance-tuning.md` — tuning matrix with concrete numbers (iPhone 14, 10k images: default ~3 min, `.fastScan()` ~90s, ROI=face ~45s), concurrency / cache / video-frame / FPS / low-power / ROI / compute-units knobs.

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
