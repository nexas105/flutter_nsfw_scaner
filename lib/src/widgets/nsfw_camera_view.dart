import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/camera_configuration.dart';
import '../api/camera_frame_result.dart';
import '../api/camera_scan_session.dart';
import '../api/camera_exceptions.dart';
import '../api/nsfw_detector.dart';
import 'nsfw_camera_hud.dart';
import 'nsfw_detection_overlay.dart';
import 'theme/nsfw_theme.dart';

typedef CameraResultCallback = void Function(CameraFrameResult result);
typedef CameraErrorCallback = void Function(Object error);

/// Live camera preview with on-device NSFW classification overlay.
///
/// Manages its own [CameraScanSession] bound to `initState`/`dispose`.
/// The native camera preview is provided via platform view (TBD).
///
/// Example:
/// ```dart
/// NsfwCameraView(
///   config: const CameraConfiguration(fps: 2),
///   onResult: (r) => print('${r.topCategory}: ${r.topConfidence}'),
///   onError: (e) => print('Error: $e'),
///   showHudOverlay: true,
/// )
/// ```
class NsfwCameraView extends StatefulWidget {
  /// Camera configuration (model, fps, resolution, mode).
  final CameraConfiguration config;

  /// Called for each classified frame.
  final CameraResultCallback? onResult;

  /// Called when a camera error occurs.
  final CameraErrorCallback? onError;

  /// Called when camera permission is denied.
  final VoidCallback? onPermissionDenied;

  /// Whether to show the HUD overlay (category badge, confidence bar).
  final bool showHudOverlay;

  /// Whether to blur the preview when NSFW is detected.
  final bool enableBlurOnNsfw;

  /// Optional blur strength when [enableBlurOnNsfw] is true.
  final double blurSigma;

  /// Theme for the HUD overlay elements.
  final NsfwGalleryTheme? theme;

  const NsfwCameraView({
    super.key,
    this.config = const CameraConfiguration(),
    this.onResult,
    this.onError,
    this.onPermissionDenied,
    this.showHudOverlay = true,
    this.enableBlurOnNsfw = false,
    this.blurSigma = 10.0,
    this.theme,
  });

  @override
  State<NsfwCameraView> createState() => _NsfwCameraViewState();
}

class _NsfwCameraViewState extends State<NsfwCameraView> {
  CameraScanSession? _session;
  CameraFrameResult? _lastResult;
  StreamSubscription<CameraFrameResult>? _resultSub;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _session = await NsfwDetector.instance.startCameraScan(widget.config);
      _resultSub = _session!.results.listen(
        _onResult,
        onError: _onError,
      );
      if (mounted) setState(() {});
    } on CameraPermissionDeniedException {
      widget.onPermissionDenied?.call();
    } catch (e) {
      _onError(e);
    }
  }

  void _onResult(CameraFrameResult result) {
    if (!mounted) return;
    setState(() => _lastResult = result);
    widget.onResult?.call(result);
  }

  void _onError(Object error) {
    if (!mounted) return;
    widget.onError?.call(error);
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    NsfwDetector.instance.stopCameraScan();
    _session = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isBlurred = widget.enableBlurOnNsfw &&
        _lastResult != null &&
        _lastResult!.isNsfw;

    return Stack(
      fit: StackFit.expand,
      children: [
        // WIDGET-01 — native camera preview via PlatformView. iOS hosts an
        // AVCaptureVideoPreviewLayer; Android hosts a CameraX PreviewView.
        // Both attach to the same capture session the analyzer is feeding,
        // via the native-side CameraPreviewRegistry. No Flutter-side
        // texture copy of analysis frames.
        _buildCameraPreview(),

        // Optional blur overlay
        if (isBlurred)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
            child: Container(color: Colors.black.withValues(alpha: 0.2)),
          ),

        // WIDGET-03 — bounding-box overlay for detection mode. Sized to the
        // same rect as the camera preview, so the painter's normalised
        // [0,1] box coordinates land on the right pixels.
        //
        // NOTE: This relies on the native preview using aspect-fill scaling
        // (iOS resizeAspectFill / Android FILL_CENTER) that matches the
        // analyser's targetResolution crop. If a future native-phase change
        // diverges (e.g. switches to letterboxed resizeAspect), the boxes
        // will drift and we'll need explicit BoxFit.cover transform math
        // (Plan WIDGET-03 Option B). Keep this comment so the next reader
        // knows where to look.
        if (_lastResult?.detections != null &&
            _lastResult!.detections!.isNotEmpty)
          Positioned.fill(
            child: IgnorePointer(
              child: NsfwDetectionOverlay(
                detections: _lastResult!.detections!,
                theme: NsfwTheme.dark(
                  gallery: widget.theme ?? NsfwGalleryTheme.defaults,
                ),
                strokeWidth: 2.0,
                showLabels: true,
                minConfidence: widget.config.detectionConfidenceThreshold,
              ),
            ),
          ),

        // HUD overlay — extracted into NsfwCameraHud (WIDGET-02) so it
        // can be widget-tested in isolation.
        if (widget.showHudOverlay && _lastResult != null)
          NsfwCameraHud(
            result: _lastResult,
            theme: widget.theme ?? NsfwGalleryTheme.defaults,
          ),
      ],
    );
  }

  /// Native camera preview via PlatformView. iOS uses [UiKitView] hosting an
  /// `AVCaptureVideoPreviewLayer`, Android uses [AndroidView] hosting a
  /// CameraX `PreviewView`. Both are wired natively to the same capture
  /// session the analyzer is reading from (see [CameraPreviewRegistry] on
  /// each platform). On unsupported platforms (desktop unit tests, web) we
  /// fall back to a themed black container.
  Widget _buildCameraPreview() {
    const viewType = 'nsfw_detect_ios/camera_preview';
    // Phase 01 didn't add `lensDirection` to CameraConfiguration; default
    // to `back` here so the native side reads a consistent value. When the
    // Dart type gains the field, swap this to `widget.config.lensDirection.name`.
    final creationParams = <String, dynamic>{
      'lensDirection': 'back',
      'resolution': widget.config.resolution.wireValue,
    };

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      );
    }
    // Desktop / web fallback (also reached in widget-test runners). Themed
    // black so the surrounding HUD still has the right background.
    return Container(color: Colors.black);
  }

}
