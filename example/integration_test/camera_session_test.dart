/// Real-device only. iOS Simulator and Android emulator do not expose
/// a camera; running this test on those targets is a no-op (it logs
/// `SKIP camera_session_test: …` and returns clean — does not fail).
/// Run on a physical device:
///
///   flutter test integration_test/camera_session_test.dart \
///     -d <device_id>
///
/// Where `<device_id>` comes from `flutter devices`.
///
/// The skip path covers two error shapes the native side can surface
/// when the host has no camera or no permission:
///   * [PlatformException] — surfaces from the method-channel call to
///     `startCameraScan` itself when the session can't even be
///     configured (e.g. no `AVCaptureDevice` on iOS Simulator, no
///     CAMERA permission ever granted on a fresh CI emulator).
///   * [CameraErrorException] / [CameraPermissionDeniedException] —
///     stream errors that arrive on the [CameraScanSession.results]
///     stream after a partially-configured start. The runtime path
///     for fully-functional devices does not enter either of these
///     branches; one [CameraFrameResult] within five seconds is the
///     happy-path expectation.
///
/// See also `example/UAT_CAMERA.md` for the full manual UAT matrix
/// that covers behaviour this automated test cannot reach (lens
/// switch, orientation, blur visual, 60-second memory).
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Camera scan emits at least one frame result over 5 seconds',
    (tester) async {
      final detector = NsfwDetector.instance;

      // fps=5 instead of the default 2 — five seconds at 5 fps gives
      // ~25 expected frames, plenty of headroom over the >=1 assertion
      // even if the first model load eats two-three frames of latency.
      const cfg = CameraConfiguration(fps: 5);

      CameraScanSession? session;
      try {
        session = await detector.startCameraScan(cfg);
      } on PlatformException catch (e) {
        // ignore: avoid_print
        print('SKIP camera_session_test: ${e.code} ${e.message}');
        return;
      } on CameraErrorException catch (e) {
        // ignore: avoid_print
        print('SKIP camera_session_test: ${e.message}');
        return;
      } on CameraPermissionDeniedException catch (e) {
        // ignore: avoid_print
        print('SKIP camera_session_test: ${e.message}');
        return;
      }

      addTearDown(() async {
        if (session != null && session.isRunning) {
          try {
            await session.stop();
          } catch (_) {/* tear-down best effort */}
        }
        try {
          await detector.stopCameraScan();
        } catch (_) {/* idempotent on the platform side */}
      });

      final received = <CameraFrameResult>[];
      Object? caught;
      final sub = session.results.listen(
        received.add,
        onError: (Object e) => caught = e,
      );
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(seconds: 5));

      // If the stream errored mid-run with a permission-denied or
      // camera-error event, treat that as a SKIP rather than a hard
      // failure — same rationale as the constructor-time catches above.
      if (caught is CameraPermissionDeniedException ||
          caught is CameraErrorException) {
        // ignore: avoid_print
        print('SKIP camera_session_test: stream error $caught');
        return;
      }

      expect(caught, isNull,
          reason: 'Camera stream surfaced a non-skippable error.');
      expect(received, isNotEmpty,
          reason:
              'Expected at least one CameraFrameResult in 5s at fps=5.');

      await session.stop();
      expect(session.isRunning, isFalse,
          reason: 'session.isRunning should be false after stop().');
    },
    // Generous timeout — first-run model load can be slow on a cold
    // device (model copy out of bundle, ML compilation).
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
