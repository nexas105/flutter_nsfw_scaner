# Cookbook

Copy-pasteable recipes for the common workflows. All snippets assume:

```dart
import 'package:nsfw_detect/nsfw_detect.dart';
```

---

## Gate a profile-picture upload

```dart
Future<bool> isUploadOk(File file) async {
  final r = await NsfwDetector.instance.scanFile(
    file.path,
    confidenceThreshold: 0.75,
  );
  return !r.isNsfw;
}
```

Use `isNsfwFile` if you only need the boolean:

```dart
if (await NsfwDetector.instance.isNsfwFile(file.path)) {
  showSnackBar('Image was flagged — please choose another.');
  return;
}
```

---

## Gate every image in a list view

```dart
ListView.builder(
  itemBuilder: (ctx, i) {
    final item = items[i];
    return NsfwModerationGate.bytes(
      item.bytes,
      child: Image.memory(item.bytes),
      confidenceFloor: 0.55, // optional: surface "review" UI in [0.55, 0.7)
      onResult: (r) => analytics.log('scan', {'cat': r.topCategory.name}),
    );
  },
)
```

`NsfwModerationGate` has `.bytes(...)`, `.file(...)`, `.asset(...)` constructors. With `confidenceFloor` the gate renders an amber "Review recommended" pill for borderline results instead of either passing or blocking.

---

## Scan a URL before showing it

```dart
final r = await NsfwDetector.instance.scanUrl(
  Uri.parse('https://cdn.example.com/uploads/img.jpg'),
  timeout: const Duration(seconds: 8),
  maxBytes: 8 * 1024 * 1024, // tighter than the 32 MB default
);
if (r.isNsfw) {
  hideImage();
  reportUrl(url);
}
```

`scanUrl` rejects non-http(s) URLs and surfaces non-2xx responses as `HttpException`. The body is streamed with the `maxBytes` cap so a misbehaving server can't OOM the caller.

---

## Whole-library scan with progress + ETA

```dart
final session = await NsfwDetector.instance.requestPermissionAndStartScan(
  ScanConfiguration.strict(includeVideos: true),
);
if (session == null) {
  // User denied permission. Show NsfwPermissionsView or your own UI.
  return;
}

session.results.listen((r) {
  if (r.isNsfw) flagged.add(r.item);
});

NsfwScanProgressBar(
  progressStream: session.progress,
  showEta: true, // appends "~30s remaining" when the rate stabilises
);

final summary = await session.done;
print('Flagged ${summary.nsfwCount} / ${summary.totalScanned}');
```

`ScanConfiguration` presets: `.strict()` (0.85), `.moderate()` (0.7), `.permissive()` (0.5), `.fastScan()` (concurrency 8). Each accepts overrides — see [configuration](configuration.md).

---

## Pick + scan in one streamed call

```dart
final session = await NsfwDetector.instance.pickAndScan(maxItems: 5);
await for (final r in session.results) {
  if (r.isNsfw) markNsfw(r.item.localIdentifier);
}
```

Picker grants per-item access — no library-permission prompt. The companion `pickMedia(...)` returns the selected items as a `List<PickedMedia>` without scanning.

---

## Find perceptual duplicates

```dart
final clusters = await NsfwDetector.instance.findDuplicates(
  items, // List<MediaItem>
  loadBytes: (id) async => await storage.read(id),
  maxHammingDistance: 5,
);

for (final cluster in clusters) {
  print('Duplicate group: ${cluster.map((m) => m.localIdentifier).join(", ")}');
}
```

dHash-based; the detector decouples from your storage via `loadBytes`. Persist hashes with `PerceptualHash.toJson()` / `fromJson(...)` for incremental dedup across launches.

---

## Redact detector boxes in place

```dart
// 1. Scan with a detector model.
final r = await NsfwDetector.instance.scanFile(
  file.path,
  modelId: ModelDescriptor.nudenet,
);

// 2. Redact the boxes (falls back to whole-image when there are no detections).
final redacted = await NsfwDetector.instance.redactBytes(
  await file.readAsBytes(),
  r,
  mode: RedactionMode.pixelate, // or .blur, .blackBox
  intensity: 0.8,               // [0..1], 1 = maximum
);
```

`redactFile(...)` is the file-in / file-out variant. `outputFormat` defaults to `'jpeg'`; pass `outputFormat: 'png'` to switch.

---

## Live camera scan with HUD

```dart
final session = await NsfwDetector.instance.startCameraScan(
  CameraConfiguration.realtime(), // ~10 fps, classifier mode
);

NsfwCameraView(
  session: session,
  showHud: true,
  blurOnNsfw: true,
)
```

Presets: `.realtime()` (10 fps), `.balanced()` (4 fps), `.batteryEfficient()` (1 fps). Switch to detection mode via `CameraConfiguration(mode: ScanMode.detection, modelId: ModelDescriptor.nudenet)`.

---

## Use any Flutter `ImageProvider`

```dart
final r = await NsfwDetector.instance.scanImageProvider(
  CachedNetworkImageProvider(url), // or AssetImage, MemoryImage, etc.
  confidenceThreshold: 0.75,
);
```

The provider is resolved + encoded to PNG once, then handed to `scanBytes`. Works with any `ImageProvider` implementation.

---

## Auto-route a mixed batch

```dart
final results = await NsfwDetector.instance.scanPaths(
  [
    'file:///storage/emulated/0/DCIM/img1.jpg',
    'https://cdn.example.com/img2.jpg',
    'PHAsset-id-from-photokit',
    'data:image/png;base64,iVBOR…',
  ],
  onProgress: (done, total) => print('$done / $total'),
);
```

Each entry is auto-routed by prefix: `file://` → `scanFile`, `http(s)://` → `scanUrl`, `data:` → base64 + `scanBytes`, anything else → `scanAsset`. Per-item failures surface as `ScanResult.failed` so the batch always completes.

---

## Persist + re-use a scan result

```dart
// At scan time.
final r = await NsfwDetector.instance.scanFile(path);
await prefs.setString('scan:${path}', jsonEncode(r.toJson()));

// Later, without re-scanning.
final raw = prefs.getString('scan:${path}');
if (raw != null) {
  final cached = ScanResult.fromJson(jsonDecode(raw));
  if (cached.isNsfw) hide();
}
```

`toJson` preserves the `confidenceThreshold` so `isNsfw` is stable across persistence. For PhotoKit / MediaStore assets the plugin also exposes a native cache:

```dart
final cached = await NsfwDetector.instance.cachedResult(localId);
if (cached != null) {
  // Hit — no re-classification ran. `cached.fromCache == true`.
}
```

Subscribe to `NsfwDetector.instance.cacheUpdates` to keep gallery badges in sync without polling.

---

## Pre-warm models on splash

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NsfwDetector.instance.init(NsfwInitOptions(
    preloadModels: [ModelIds.openNsfw2],
    downloadIfMissing: [ModelIds.openNsfw2], // auto-download on first launch
    enableNativeLogging: kDebugMode,
    defaultThreshold: 0.75,
  ));
  runApp(const MyApp());
}
```

Skipping `init` is fine — the plugin lazy-loads on first use, at the cost of a slightly slower first scan.

---

## Render the permission UI

```dart
NsfwPermissionsView(
  kinds: const [PermissionKind.photoLibrary, PermissionKind.camera],
  onPermissionChanged: (kind, status) => debugPrint('$kind → $status'),
  onOpenSettings: () => AppSettings.openAppSettings(), // host wires this
)
```

The plugin doesn't depend on `permission_handler` or `app_settings`. Pass `onOpenSettings` to wire your preferred deep-link package; the widget hides the Settings button when the callback is null.

---

## Headless boolean variants

```dart
final blockedFile  = await NsfwDetector.instance.isNsfwFile(path);
final blockedBytes = await NsfwDetector.instance.isNsfwBytes(bytes);
final blockedAsset = await NsfwDetector.instance.isNsfwAsset(localId);
```

Each returns a `Future<bool>` — use them when the full `ScanResult` shape isn't needed.

---

## Apply a safety profile

```dart
final profile = NsfwSafetyProfile.teen; // .kidSafe / .teen / .adult
final r = await NsfwDetector.instance.scanFile(path);

if (!profile.evaluate(r)) {
  block(reason: 'Fails ${profile.ageRating} profile');
}
```

`evaluate` is the one-call check — `safe` / `unknown` always pass; NSFW categories must score below `profile.recommendedThreshold`; `failed` / `skipped` results route to manual review. `profile.toScanConfiguration()` translates the profile straight into a `ScanConfiguration`.

---

## Drive the model manager UI

```dart
final manager = NsfwDetector.instance.models; // NsfwModelManager

StreamBuilder<ModelStateSnapshot>(
  stream: manager.changes,
  builder: (ctx, snap) => ModelList(
    models: snap.data?.descriptors ?? const [],
    onDownload: (id) => manager.ensureReady(id, onProgress: ...),
    onDelete:   (id) => manager.remove(id),
  ),
);
```

`manager.changes` emits whenever a model is loaded, unloaded, downloaded, or deleted — bind it to your UI to avoid hand-rolling the state machine.

---

## Apply per-category thresholds

```dart
final config = ScanConfiguration.moderate().copyWith(
  thresholdsByCategory: {
    NsfwCategory.explicitNudity: 0.5,  // flag aggressively
    NsfwCategory.nudity: 0.7,
    NsfwCategory.suggestive: 0.95,     // tolerate — only near-certain trips it
  },
);

final session = await NsfwDetector.instance.startScan(config);
```

`thresholdsByCategory` (2.4.0) overrides the scalar `confidenceThreshold` per category — `ScanResult.isNsfw` and the category shortcuts walk each label against its own threshold; unmapped categories fall back to the scalar. Re-score a result you already hold without re-running inference:

```dart
final stricter = result.withThresholds({NsfwCategory.suggestive: 0.6});
if (stricter.isSuggestive) routeToReview();
```

See [configuration](configuration.md#per-category-thresholds) for the full contract.

---

## Detect, then classify each region

```dart
final r = await NsfwDetector.instance.scanFileDetectThenClassify(
  file.path,
  detectorModelId: ModelDescriptor.nudenet,
  // classifierModelId defaults to ModelIds.openNsfw2
);

for (final d in r.detections) {
  // d.labels — per-region NSFW classification (null on plain detection runs).
  final top = d.labels?.first;
  debugPrint('${d.label} box → ${top?.category.name} ${top?.confidence}');
}
```

`scanBytesDetectThenClassify(...)` is the bytes variant. The pipeline (2.4.0) runs the detector once, then the classifier on every emitted crop, attaching the crop-level `List<NsfwLabel>` to each `BodyPartDetection.labels`. Stronger signal than detector-only (graded confidence per region) or classifier-only (per-region attribution), at the cost of one extra classifier call per box. It throws `ArgumentError` when the detector pass finds no boxes — fall back to plain `scanFile` with the classifier in that case.

`detectorModelId` must be a registered detector kind. Preload both the detector and the classifier via `NsfwInitOptions.preloadModels` so the second-pass classifier is warm.

---

## Remember moderator decisions

```dart
// Install a persistent store once, at startup.
await NsfwDetector.instance.useDecisionStore(SharedPreferencesDecisionStore());

// A moderator overrides a result.
await NsfwDetector.instance.decisions.mark('asset-id', ScanDecision.allow);

// Later scans of that asset come back with the override applied.
final r = await NsfwDetector.instance.scanAsset('asset-id');
// r.userDecision == ScanDecision.allow
// .allow forces r.isNsfw == false; .block forces r.isNsfw == true.
```

`DecisionStore` (2.4.0) is a moderator-override store keyed by an asset's `localIdentifier`. `InMemoryDecisionStore` is the dependency-free default (lost on cold start); `SharedPreferencesDecisionStore` persists across restarts. Decisions are applied automatically by `startScan` / `pickAndScan` and by every one-shot scan (`scanAsset` / `scanFile` / `scanBytes` / `scanUrl` / `scanImageProvider`) whose platform-returned `localIdentifier` matches a stored entry. Camera live mode is not wired — frames lack a persistent identifier.

Clear an override with `ScanDecision.reset`:

```dart
await NsfwDetector.instance.decisions.mark('asset-id', ScanDecision.reset);
```

Subclass `DecisionStore` for `sqflite` / `isar` / `hive` backends. `store.changes` streams `(localId, decision)` updates — the detector subscribes to it to keep its sync lookup cache primed.

---

## Wire telemetry hooks

```dart
NsfwDetector.instance.onTelemetryEvent = (TelemetryEvent e) {
  switch (e.type) {
    case TelemetryEventType.classifyTime:
      myAnalytics.timing('nsfw.scan', e.elapsed!, {
        'model': e.modelId,
        'bucket': e.confidenceBucket, // 0..9 decile, raw score suppressed
      });
    case TelemetryEventType.downloadFinished:
      myAnalytics.event('nsfw.model.downloaded', {'model': e.modelId});
    default:
      break;
  }
};
```

`onTelemetryEvent` (2.4.0) is a single sink for structured scan / download / lifecycle events. It is a **local callback** — the plugin sends nothing over the network; events go only to your handler. Confidence is binned into a `0..9` decile so rollups stay PII-free by default. `localId` is always `null` unless you opt in:

```dart
NsfwDetector.instance.includeLocalIdsInTelemetry = true;
```

The handler runs inline with the scan pipeline — keep it fast and never throw (exceptions are swallowed, but a slow handler backs up scanning). Pipe heavyweight processing through an `Isolate` or a queue.

---

## Localize plugin strings

```dart
void main() {
  // App-wide override — bundled EN / DE / ES / FR / JA.
  NsfwLocalizations.current = const NsfwLocalizationsDe();
  runApp(const MyApp());
}
```

`NsfwLocalizations` (2.5.0) is a plain-Dart string bundle — no `flutter_localizations` codegen, no `.arb` files, no new dependencies. It covers NSFW category names, permission-status hints, confidence buckets, safety-profile age ratings, and (since 2.5.2) widget button labels. Pick a bundle by BCP-47 tag:

```dart
NsfwLocalizations.current = NsfwLocalizations.resolve('es-MX'); // → Spanish
```

`resolve` is case-insensitive and ignores the region subtag; unknown tags fall back to English. Localized helpers default to `NsfwLocalizations.current` but accept an explicit bundle per call:

```dart
final name = NsfwCategory.nudity.localizedName(const NsfwLocalizationsFr());
final hint = status.localizedMessage(); // uses NsfwLocalizations.current
final desc = result.localizedConfidenceDescription();
```

Legacy getters (`displayName`, `userMessage`, `confidenceDescription`, `ageRating`) always return English regardless of the override, so pre-2.5.0 callers see no behaviour change.

For a language outside the bundled five, subclass `NsfwLocalizations`, implement the abstract getters, and install it at startup:

```dart
class NsfwLocalizationsPtBr extends NsfwLocalizations {
  const NsfwLocalizationsPtBr();
  @override String get languageCode => 'pt-BR';
  @override String get categoryNudity => 'Nudez';
  // … the remaining strings
}

NsfwLocalizations.current = const NsfwLocalizationsPtBr();
```
