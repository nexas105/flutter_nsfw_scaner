# Camera Live Pipeline — Manual UAT (v2.1.0)

Run before tagging v2.1.0. Two devices required: one physical iPhone
(iOS 16+), one physical Android phone (API 24+). Simulator / emulator
runs do not count — they have no camera.

The companion automated check is
`example/integration_test/camera_session_test.dart`. That test only
asserts ≥ 1 `CameraFrameResult` over a 5-second window; the matrix
below covers everything automation cannot reach (lens switch,
orientation, blur visual, 60-second memory profile, permission
denial UX).

For each row, mark PASS / FAIL with a short note. File a bug for any
FAIL before release.

## 1. Real-device — iPhone, classification mode

- [ ] Open the app, switch to the **Camera** tab.
- [ ] Permission prompt appears on first run; tap Allow.
- [ ] Default model loads, mode is `Classify`, blur is OFF.
- [ ] Press Start. Preview shows the rear camera. HUD displays a
      category label and confidence bar.
- [ ] Point at a clearly safe scene (a wall) — top label trends to
      `safe` / `neutral` and confidence > 0.7.
- [ ] Press Stop. Preview goes idle within ~1s. No errors in
      `flutter logs`.

## 2. Real-device — iPhone, detection mode

- [ ] In Camera tab, switch mode to `Detect`. Pipeline restarts
      cleanly (preview blanks for ~1s, comes back).
- [ ] Bounding boxes draw on top of the preview when applicable.
- [ ] Boxes follow the subject as the camera moves; no skew when
      rotating the device.

## 3. Real-device — Android, classification mode

- [ ] Same flow as §1 on a physical Android device.
- [ ] CAMERA permission prompt fires on first run; granting it starts
      the preview without app restart.

## 4. Real-device — Android, detection mode

- [ ] Same flow as §2 on the same Android device.

## 5. Orientation rotation

- [ ] Lock device orientation OFF (Portrait → Landscape →
      Portrait Upside Down → Landscape Right).
- [ ] Preview and HUD re-layout without crash.
- [ ] Bounding boxes (detection mode) follow the rotated frame — no
      offset, no inverted aspect.

## 6. Lens switch (if Phase 04 ships front/back toggle)

- [ ] Toggle from rear → front lens. Pipeline restarts cleanly.
- [ ] Toggle back. No leaked session — memory does not grow per
      toggle (see §9).

## 7. Permission denial path

- [ ] Settings → app permissions → revoke Camera.
- [ ] Reopen app, switch to Camera tab, press Start.
- [ ] User-visible error surfaces (snackbar / inline message). No
      crash, no hang. The screen returns to idle state.

## 8. Blur overlay visual check

- [ ] Toggle Blur ON.
- [ ] Aim camera at a NSFW reference image on a second screen (use
      any of the OpenNSFW2 test fixtures from `models_cache/`).
- [ ] When the top label flips to a NSFW category at ≥ confidence
      threshold, preview blurs immediately. When pointed away, blur
      disappears within one frame.

## 9. 60-second memory profile

### iOS

- [ ] Run Xcode → Instruments → Allocations on the example app.
- [ ] Start a 60-second classification scan in the Camera tab.
- [ ] Persistent bytes plateau (do not grow steadily). Live
      `CVPixelBuffer` allocation count returns to baseline after
      Stop.

### Android

- [ ] Run Android Studio → Profiler → Memory.
- [ ] Same 60s flow.
- [ ] Java + Native heap return to baseline after Stop. No
      `ImageProxy` leak warnings in `logcat`.

## 10. Integration-test sanity (companion automated check)

- [ ] On a real iPhone:
      `flutter test integration_test/camera_session_test.dart -d <iphone>`
      passes.
- [ ] On a real Android device:
      `flutter test integration_test/camera_session_test.dart -d <android>`
      passes.
- [ ] On an iOS Simulator / Android emulator: the same command does
      NOT fail — it logs `SKIP camera_session_test: …` and exits
      clean.

## Sign-off

- iPhone tested: ______________________ (model, iOS version)
- Android tested: ____________________ (model, Android version)
- Tester: ___________________ Date: ___________
