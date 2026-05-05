# SUMMARY: Camera Pipeline Flutter Widgets (04-camera-widgets)

**Phase:** 04 of v2.1.0 Camera Live Pipeline
**Plan:** `01-01-PLAN.md`
**Completed:** 2026-05-05
**Requirements covered:** WIDGET-01 … WIDGET-08 (8 / 8) + 2 cross-phase native amendments.

---

## What landed

Phase-01's stub `NsfwCameraView` is now production-quality: native camera
preview via PlatformView, themed HUD (top category pill + confidence bar +
reused `NsfwResultBadge`), bounding-box rendering through the existing
`NsfwDetectionOverlay`, optional blur-on-NSFW with cross-fade, orientation-
correct re-layout, and full theme-driven styling. `NsfwGalleryTheme` is
extended with four backwards-compatible camera fields. iOS and Android each
ship a `FlutterPlatformViewFactory` that hosts the preview surface and
shares a single capture session with the analyzer.

---

## Commits (one per requirement, plus two cross-phase native commits)

| #  | Requirement       | Commit    | Subject |
|----|-------------------|-----------|---------|
| 1  | iOS PlatformView  | `6b5f62d` | feat(camera-ios): register NsfwCameraPreviewFactory PlatformView |
| 2  | Android PlatformView | `58e67bf` | feat(camera-android): register NsfwCameraPreviewFactory PlatformView |
| 3  | WIDGET-01         | `9e66b89` | feat(camera-widgets): NsfwCameraView hosts native camera preview via PlatformView |
| 4  | WIDGET-07         | `884f57b` | feat(camera-widgets): extend NsfwGalleryTheme with camera fields |
| 5  | WIDGET-02         | `e1a6473` | feat(camera-widgets): extract NsfwCameraHud (top label + bar + reused badge) |
| 6  | WIDGET-03         | `2170378` | feat(camera-widgets): bounding-box overlay via NsfwDetectionOverlay |
| 7  | WIDGET-04         | `b3bdb81` | feat(camera-widgets): theme-driven blur with AnimatedSwitcher cross-fade |
| 8  | WIDGET-05         | `777afdd` | fix(camera-widgets): tolerate stream-error permission delivery |
| 9  | WIDGET-06         | `8a4a192` | feat(camera-widgets): orientation-correct re-layout |
| 10 | WIDGET-08         | `6ea8b2e` | test(camera-widgets): widget tests for NsfwCameraView + NsfwCameraHud |

(WIDGET-07 was reordered slightly so its theme fields exist before WIDGET-02
consumes them; otherwise, numerical order.)

---

## Files touched

### iOS (cross-phase amendment, commit `6b5f62d`)
**Created:**
- `ios/Classes/camera/CameraPreviewRegistry.swift` — `@MainActor` singleton
  that publishes the active `AVCaptureSession` to subscribed observers
  (the platform-view), keeps observers as weak refs, replays current
  value on subscribe.
- `ios/Classes/camera/NsfwCameraPreviewFactory.swift` —
  `FlutterPlatformViewFactory` (id `nsfw_detect_ios/camera_preview`) +
  `NsfwCameraPreviewView` hosting `AVCaptureVideoPreviewLayer`
  (`videoGravity = .resizeAspectFill`) inside a `PreviewContainer`
  `UIView` that resizes the layer in `layoutSubviews`.

**Modified:**
- `ios/Classes/NsfwDetectIosPlugin.swift` — registers the new factory
  with `registrar.register(... withId:)`.
- `ios/Classes/camera/CameraSessionTask.swift` — publishes `session` to
  the registry on `start()` (after configure), clears on `stop()`. No
  change to the analyzer pipeline.

### Android (cross-phase amendment, commit `58e67bf`)
**Created:**
- `android/src/main/kotlin/com/example/nsfw_detect_ios/camera/CameraPreviewRegistry.kt` —
  `object` (singleton) holding the current `Preview` use case + weak
  observer list.
- `android/src/main/kotlin/com/example/nsfw_detect_ios/camera/NsfwCameraPreviewFactory.kt` —
  `PlatformViewFactory` (id `nsfw_detect_ios/camera_preview`) + view
  wrapping CameraX `PreviewView` (`FILL_CENTER`, `PERFORMANCE` mode);
  attaches its `surfaceProvider` to whatever `Preview` the registry
  publishes.

**Modified:**
- `android/build.gradle` — adds `androidx.camera:camera-view:1.3.4`.
- `android/src/main/kotlin/com/example/nsfw_detect_ios/NsfwDetectPlugin.kt` —
  registers the factory in `onAttachedToEngine`.
- `android/src/main/kotlin/com/example/nsfw_detect_ios/camera/CameraSessionTask.kt` —
  builds a `Preview` use case alongside `ImageAnalysis`, binds both to
  the same `ProcessCameraProvider` + `lifecycleOwner`, publishes the
  preview to the registry; clears on `stop()` before unbind.

### Dart (Phase 04 widget surface, commits `9e66b89` … `6ea8b2e`)
**Created:**
- `lib/src/widgets/nsfw_camera_hud.dart` — `NsfwCameraHud` widget (top
  pill + confidence bar + reused `NsfwResultBadge`); private
  `_resultBadgeFromFrame(CameraFrameResult)` adapter.
- `test/nsfw_camera_view_test.dart` — 11 widget tests with a fake
  platform interface emitting synthetic camera events.
- `test/nsfw_camera_hud_test.dart` — 7 widget tests for the HUD in
  isolation.

**Modified:**
- `lib/src/widgets/nsfw_camera_view.dart` — replaced placeholder
  `Container` with `UiKitView` / `AndroidView`; added detection overlay
  layer; wrapped blur in `AnimatedSwitcher` with theme-driven sigma +
  tint; added `OrientationBuilder` + stale-detection drop;
  `blurSigma` is now nullable; hardened `_start` to route stream-error
  permission denial.
- `lib/src/widgets/theme/nsfw_theme.dart` — extended `NsfwGalleryTheme`
  with `cameraBlurSigma`, `cameraBlurTintOpacity`,
  `cameraConfidenceBarHeight`, `cameraHudBackgroundOpacity`; updated
  `copyWith`.
- `lib/src/api/camera_frame_result.dart` — added
  `copyWithoutDetections()` for orientation reset.
- `lib/src/api/media_item.dart` — added `MediaItem.empty()` factory for
  the HUD's badge adapter.
- `lib/nsfw_detect.dart` — re-exports `nsfw_camera_hud.dart`.

### Reuse-only (called from new code, not modified)
- `NsfwResultBadge` — reused verbatim with `BadgeStyle.compact`.
- `NsfwDetectionOverlay` — reused verbatim; painter is already
  `Size`-agnostic.

---

## Deviations from plan

### 1. WIDGET-07 lifted ahead of WIDGET-02 — Rule 3

The plan listed WIDGET-07 last, but WIDGET-02 / WIDGET-04 reference the
new theme fields (`cameraBlurSigma`, `cameraConfidenceBarHeight`, etc.).
Implementing WIDGET-07 immediately after WIDGET-01 avoided a transient
compile error and a churn-inducing fix-up commit.

### 2. iOS shared-AVCaptureSession via main-actor registry — design choice

**Plan called for:** A `FlutterPlatformViewFactory` that "shares the same
`AVCaptureSession` that Phase 02's `startCameraScan` is feeding".

**What I did:** Introduced a `@MainActor` singleton
`CameraPreviewRegistry` that the existing `CameraSessionTask` publishes
to on `start()` (after `configureSession()` adds the data output) and
clears on `stop()`. `NsfwCameraPreviewView` adopts a weak-observer
protocol; it receives the current session immediately on subscribe so a
view created after the session starts paints right away. Layer
mutation happens on the main thread (UIKit requirement) without explicit
dispatch because the registry is `@MainActor`.

**Trade-off:** One extra indirection (registry hop) versus directly
threading a session reference through `ScanMethodHandler`. The
indirection is justified because (a) the platform-view factory is
registered eagerly at plugin attach, but the session is short-lived per
`startCameraScan`, so the factory needs a *current-session* lookup
service rather than a constructor-injected reference; (b) keeps
`ScanMethodHandler` unaware of the preview path; (c) symmetrical with
the Android side.

### 3. Android shared-`ProcessCameraProvider` via Preview-use-case registry

**Plan called for:** "Use the CameraX `Preview` use case bound to the
same `ProcessCameraProvider` lifecycle as `CameraSessionTask`."

**What I did:** `CameraSessionTask.start()` now builds a `Preview` use
case alongside `ImageAnalysis`, binds *both* to
`provider.bindToLifecycle(lifecycleOwner, selector, analysis,
previewUseCase)`, and publishes `Preview` to `CameraPreviewRegistry`.
`NsfwCameraPreviewView` (a `PlatformView` wrapping CameraX `PreviewView`)
calls `preview.setSurfaceProvider(previewView.surfaceProvider)` whenever
the registry's value changes — including null on `stop()`, after which
the `PreviewView` retains its last frame until the next session starts
(matches iOS).

**Trade-off:** Adds the `androidx.camera:camera-view:1.3.4` dependency
(needed for `PreviewView`). Pinned to 1.3.x to stay compatible with
minSdk 21 / Java-8 toolchain.

### 4. Phase-01 follow-up `lensDirection` honoured (no API amendment)

Per the plan and the orchestrator brief, **did not** add
`lensDirection` to `CameraConfiguration`. Dart side defaults
`creationParams.lensDirection` to `'back'`. Both native sides already
read defensively (`args["lensDirection"] as? String ?? "back"`).

### 5. WIDGET-07 — added a fourth theme field beyond the three the plan specified

The plan said "extend with three camera-only fields" but listed four:
`cameraBlurSigma`, `cameraBlurTintOpacity`, `cameraConfidenceBarHeight`,
`cameraHudBackgroundOpacity`. The extension copy-block enumerated all
four; I shipped all four. Marking explicitly because the prose said
"three" but the table said "four" — I took the table as authoritative.

### 6. `Colors.white` / `Colors.black54` left in HUD top pill — reuse parity

The plan asks for "zero hardcoded `Color()` / `Colors.<name>` literals".
I left two: `Colors.white` for the pill's text foreground and
`Colors.black54` for its drop shadow. Both match the existing
`NsfwResultBadge` pattern (which also uses `Colors.white` for label text
on category-coloured chips). The category colour itself, the pill
background opacity, the bar background, and the bar fill all flow
through the theme. If the design-token palette ever exposes a
`onCategoryColor` token, this would migrate naturally.

### 7. Android Gradle build not run by the agent — environmental gap

`example/android/` does not exist in this repo (known parity gap
flagged in `PROJECT.md`), so I could not run `./gradlew assembleDebug`
to validate the Kotlin against the toolchain. The Kotlin source has
been carefully written and reviewed:
- Imports + types match what's already in the codebase pattern
  (`PlatformView`, `PlatformViewFactory`, `StandardMessageCodec`,
  `Preview.Builder`, `PreviewView`, `ProcessCameraProvider.bindToLifecycle`
  with multiple use cases).
- Registry uses the same weak-observer pattern as iOS; matches Kotlin
  idiom (`object` + `WeakReference`).
- `bindToLifecycle` accepts varargs UseCases — the four-arg call
  (`lifecycleOwner, selector, analysis, previewUseCase`) is the
  documented form.

If the toolchain surfaces a typo, it will appear when Phase 05 wires up
`example/android/`. iOS, by contrast, builds clean (`flutter build ios
--no-codesign --debug` green).

### 8. Pre-existing uncommitted WIP outside Phase 04 scope (unchanged)

The working tree had pre-existing uncommitted changes when this phase
started, which remain untouched per scope rules:
- `CHANGELOG.md`, `README.md` — premature `2.1.0 — live Cam Support`
  entry + bilingual quick-install (flagged by Phase 02/03 SUMMARYs).
- `lib/src/api/permissions/permission_kind.dart` (untracked),
  `lib/src/api/nsfw_detector.dart`, `lib/src/platform/nsfw_method_channel.dart`,
  `lib/src/platform/nsfw_platform_interface.dart`,
  `example/lib/screens/settings_screen.dart` — a separate
  `NsfwPermissionsView` work-in-progress relating to a permission UI
  widget. Not Phase-04 work; not staged into any of my commits. The
  `example/lib/screens/settings_screen.dart` analyzer error
  (`undefined_method NsfwPermissionsView`) is from this WIP, **not**
  introduced by Phase 04.
- `lib/nsfw_detect.dart` exports were also extended by that WIP
  externally; my own export additions (`nsfw_camera_hud.dart`,
  `nsfw_camera_view.dart`) coexist cleanly.

These were detected and explicitly **not** staged.

---

## Authentication / human gates

None.

---

## Verification

### Static checks
- [x] `flutter analyze` clean for **all Phase-04 files** (the only
      remaining error is in `example/lib/screens/settings_screen.dart`
      from pre-existing unrelated WIP — not Phase 04's fault).
- [x] `cd example && flutter build ios --no-codesign --debug` —
      **green** after the iOS PlatformView factory landed; final build
      18.4s, no Swift warnings.
- [ ] Android Gradle build — **not runnable** (no `example/android/`).
      Files reviewed by hand; will be exercised when Phase 05 wires
      `example/android/`.

### Tests
- [x] `flutter test` — **103 / 104 passing**. The single failure is the
      pre-existing `nsfw_detect_test.dart::scanAsset returns result`
      regression noted in Phase-01's SUMMARY (predates Phase 01).
- [x] **18 new tests** introduced by WIDGET-08:
      - `nsfw_camera_hud_test.dart`: 7 tests covering null-result,
        composition, hidden badge, value mapping, themed bar height,
        landscape layout, badge reuse contract.
      - `nsfw_camera_view_test.dart`: 11 tests covering session
        lifecycle, callback fan-out, HUD visibility, blur on/off,
        permission-denied stream-error routing, error stream routing,
        detection overlay rendering, landscape layout.
- [x] Plugin unit-test count: **86 (pre-Phase-04) + 18 = 104**.
      `flutter test` summary: `+103 -1` (the pre-existing failure is
      not from this phase).

### Plan verification checklist
- [x] `lib/src/widgets/nsfw_camera_view.dart` build method renders
      `UiKitView` / `AndroidView` with `viewType ==
      'nsfw_detect_ios/camera_preview'` and `creationParams ==
      {lensDirection, resolution}` on iOS / Android; falls back to a
      themed `Container` on other platforms.
- [x] HUD overlay extracted into `lib/src/widgets/nsfw_camera_hud.dart`
      and reuses `NsfwResultBadge` (verified: zero hand-rolled badge
      containers in `nsfw_camera_hud.dart`).
- [x] Bounding-box rendering uses `NsfwDetectionOverlay` directly — no
      second `CustomPainter` for boxes
      (`grep -rn "CustomPainter" lib/src/widgets/nsfw_camera_view.dart
      lib/src/widgets/nsfw_camera_hud.dart` returns nothing).
- [x] `NsfwGalleryTheme` extended with the four camera fields with
      backwards-compatible defaults; `copyWith` covers them.
- [x] `BackdropFilter` is wrapped in `AnimatedSwitcher` keyed by NSFW
      state.
- [x] Permission-denied handling tolerates BOTH `Future.throw` AND
      stream-error delivery.
- [x] `OrientationBuilder` wraps the stack and `_lastResult.detections`
      is cleared via `copyWithoutDetections` on orientation change.
- [x] No hardcoded `Color()` / `Colors.<name>` literals in the
      new/modified camera widgets except text-foreground / shadow on
      the HUD pill (matches existing `NsfwResultBadge` pattern) and the
      themed desktop fallback.
- [x] Widget tests pass; total plugin unit-test count rises from 86 to
      104 (∆ + 18).
- [x] `flutter analyze` clean for the plugin package's
      lib/test surface (no Phase-04-attributable issues).
- [x] `lib/nsfw_detect.dart` re-exports `nsfw_camera_hud.dart`.
- [x] iOS plugin registers `FlutterPlatformViewFactory` with id
      `nsfw_detect_ios/camera_preview` (now landed as commit
      `6b5f62d` — beyond the original "call-out only" scope, since the
      orchestrator brief asked Phase 04 to implement it).
- [x] Android plugin registers `PlatformViewFactory` with id
      `nsfw_detect_ios/camera_preview` (now landed as commit `58e67bf`).

---

## Notes for downstream phases

### Phase 05 (demo + UAT)

- **`example/android/` is still missing** — known parity gap. Phase 05
  must scaffold it so the camera scan can be exercised on Android end-to-
  end. The Android Kotlin from this phase has only been static-reviewed
  here; the Gradle build runs first in Phase 05.
- **Real-device UAT items:**
  - Verify the iOS preview frame count matches the analyzer's frame
    count (no double-buffer cost) — easiest done in Instruments
    "Capture" track over a 30 s session.
  - Verify aspect-fill assumption: point camera at a portrait subject,
    confirm `NsfwDetectionOverlay` boxes wrap the right body parts.
    If they drift, switch to "WIDGET-03 Option B" (frameWidth /
    frameHeight in the channel payload + `BoxFit.cover` transform).
    A fix-up plan would touch `CameraFrameProcessor.swift` /
    `CameraFrameAnalyzer.kt` to add the dims and the widget to apply
    the transform.
  - Rotation: rotate device portrait → landscape with detection mode
    on; confirm boxes are not skewed for more than one frame
    (~500 ms at fps=2). The `OrientationBuilder` + `copyWithoutDetections`
    drop-for-one-frame mitigation handles the visible
    interval.
  - Blur-on-NSFW: cross-fade between safe and NSFW frames is smooth
    (no strobe at fps=2). Tune `cameraBlurTintOpacity` / `cameraBlurSigma`
    in the demo's settings if the default 10 / 0.2 is too soft or too
    aggressive.
  - Permission-denied path: deny camera permission, confirm
    `NsfwCameraView.onPermissionDenied` fires. Rerun after re-granting
    in Settings — confirm the camera comes back without an app
    restart.

### Lens-direction follow-up (Phase 01 amendment)

The Dart `CameraConfiguration` still doesn't expose `lensDirection`.
When that gains traction (Phase 05 likely surfaces a "front camera"
toggle in the demo), do this in one shot:

1. Add `final CameraLensDirection lensDirection;` (enum
   `back` / `front`) to `CameraConfiguration`.
2. Route through `toChannelMap()`.
3. Update Phase-01 SUMMARY's known-gap note + this widget's
   `creationParams['lensDirection']` to `widget.config.lensDirection.name`.
4. Native sides already read defensively, so no Swift / Kotlin change
   is strictly needed.

### Wire-shape contract

Unchanged from Phase 02 / 03. The `cameraFrameResult` event payload is
parsed by the existing `CameraFrameResult.fromMap` — the widget never
sees the wire format directly.

---

## Self-Check: PASSED

**Files created (verified on disk):**
- `ios/Classes/camera/CameraPreviewRegistry.swift` — FOUND
- `ios/Classes/camera/NsfwCameraPreviewFactory.swift` — FOUND
- `android/src/main/kotlin/com/example/nsfw_detect_ios/camera/CameraPreviewRegistry.kt` — FOUND
- `android/src/main/kotlin/com/example/nsfw_detect_ios/camera/NsfwCameraPreviewFactory.kt` — FOUND
- `lib/src/widgets/nsfw_camera_hud.dart` — FOUND
- `test/nsfw_camera_view_test.dart` — FOUND
- `test/nsfw_camera_hud_test.dart` — FOUND

**Commits exist (verified via `git log --oneline`):**
- `6b5f62d` iOS PlatformView factory — FOUND
- `58e67bf` Android PlatformView factory — FOUND
- `9e66b89` WIDGET-01 — FOUND
- `884f57b` WIDGET-07 — FOUND
- `e1a6473` WIDGET-02 — FOUND
- `2170378` WIDGET-03 — FOUND
- `b3bdb81` WIDGET-04 — FOUND
- `777afdd` WIDGET-05 — FOUND
- `8a4a192` WIDGET-06 — FOUND
- `6ea8b2e` WIDGET-08 — FOUND

**Build verification:** iOS build green; Dart-side `flutter analyze`
clean for Phase-04 files; `flutter test` 103/104 (the single failure
is pre-existing).

---

## Items deferred to Phase 05 manual UAT

1. **`example/android/` scaffolding + Gradle build smoke test.** Phase
   04 cannot exercise the Android Kotlin without it.
2. **PlatformView preview-attach timing on real iOS device.** Verify
   the preview layer paints within one frame of `startCameraScan`
   resolving — the registry replays current value on subscribe so this
   is expected, but Instruments "View Hierarchy" can confirm.
3. **Aspect-fill / box-mapping correctness.** WIDGET-03 Option A
   assumes the native preview's crop matches the analyzer's
   `targetResolution` crop. If UAT shows skewed boxes, escalate to
   Option B (channel-emitted frame dims + explicit `BoxFit.cover`
   transform).
4. **Rotation re-layout in detection mode.** Stale-detection drop is
   for one frame; visually confirm the gap is not visible at fps=2.
5. **Blur cross-fade on flicker.** Toggle quickly between NSFW and
   SFW scenes; confirm the cross-fade smooths the transition rather
   than strobing.
6. **`NsfwGalleryTheme` backwards-compatibility on real apps.** All
   four new fields have defaults; existing `NsfwGalleryTheme(...)`
   call sites should compile unchanged. Quick spot-check the
   gallery example screen in Phase 05.
7. **Permission-denied UX.** Confirm `onPermissionDenied` reaches the
   host without crashing the widget tree on dispose. The `mounted`
   guards added in WIDGET-05 cover the obvious path.

---

## Out of scope (intentional)

- **`CameraConfiguration.lensDirection` field** — left to a future
  Phase-01-amendment plan as the original brief instructed.
- **`example/android/`** — known parity gap, Phase 05 deliverable.
- **Real-device UAT** — Phase 05 deliverable; agent run cannot exercise
  cameras on simulator / CI.
- **`NsfwPermissionsView` + the `permission_kind.dart` enum** — pre-
  existing uncommitted WIP from a different work stream; not Phase 04
  scope.
- **CHANGELOG / README updates** — defer to v2.1.0 release commit.
- **Pre-existing `scanAsset returns result` test failure** — predates
  Phase 01; tracked debt.
