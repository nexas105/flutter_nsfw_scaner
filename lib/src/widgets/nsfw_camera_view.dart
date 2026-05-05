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
import 'theme/nsfw_design_tokens.dart';
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

  /// Optional override for blur strength when [enableBlurOnNsfw] is true.
  /// When null, falls back to [NsfwGalleryTheme.cameraBlurSigma].
  final double? blurSigma;

  /// Theme for the HUD overlay elements, blur strength, and tint.
  final NsfwGalleryTheme? theme;

  const NsfwCameraView({
    super.key,
    this.config = const CameraConfiguration(),
    this.onResult,
    this.onError,
    this.onPermissionDenied,
    this.showHudOverlay = true,
    this.enableBlurOnNsfw = false,
    this.blurSigma,
    this.theme,
  });

  @override
  State<NsfwCameraView> createState() => _NsfwCameraViewState();
}

class _NsfwCameraViewState extends State<NsfwCameraView> {
  CameraScanSession? _session;
  CameraFrameResult? _lastResult;
  StreamSubscription<CameraFrameResult>? _resultSub;
  Orientation? _lastOrientation;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _session = await NsfwDetector.instance.startCameraScan(widget.config);
      // WIDGET-05 — permission denied may arrive as either a Future throw
      // (immediate-deny path) or a stream error from the native side
      // (`cameraPermissionDenied` event). The listener routes the latter
      // to onPermissionDenied so callers see one consistent entry point.
      _resultSub = _session!.results.listen(
        _onResult,
        onError: (Object error) {
          if (error is CameraPermissionDeniedException) {
            if (mounted) widget.onPermissionDenied?.call();
          } else {
            _onError(error);
          }
        },
      );
      if (mounted) setState(() {});
    } on CameraPermissionDeniedException {
      if (mounted) widget.onPermissionDenied?.call();
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
    return OrientationBuilder(
      builder: (context, orientation) {
        // WIDGET-06 — drop the stale detection boxes for one frame on
        // rotation. Labels + confidence are size-agnostic and stay valid;
        // boxes were computed at the old orientation and would skew
        // visibly if we kept them. The next analyzer result repopulates
        // them at the new orientation.
        if (_lastOrientation != null &&
            _lastOrientation != orientation &&
            _lastResult?.detections != null) {
          _lastResult = _lastResult!.copyWithoutDetections();
        }
        _lastOrientation = orientation;
        return _buildStack();
      },
    );
  }

  Widget _buildStack() {
    final effectiveTheme = widget.theme ?? NsfwGalleryTheme.defaults;
    final isBlurred = widget.enableBlurOnNsfw &&
        _lastResult != null &&
        _lastResult!.isNsfw;
    final sigma = widget.blurSigma ?? effectiveTheme.cameraBlurSigma;

    return Stack(
      fit: StackFit.expand,
      children: [
        // WIDGET-01 — native camera preview via PlatformView. iOS hosts an
        // AVCaptureVideoPreviewLayer; Android hosts a CameraX PreviewView.
        // Both attach to the same capture session the analyzer is feeding,
        // via the native-side CameraPreviewRegistry. No Flutter-side
        // texture copy of analysis frames.
        _buildCameraPreview(),

        // WIDGET-04 — themed blur-on-NSFW with cross-fade so a single safe
        // frame in a stream of NSFW frames doesn't strobe the user. Sigma
        // and tint flow through the theme.
        AnimatedSwitcher(
          duration: NsfwAnimations.standard.normal,
          child: isBlurred
              ? BackdropFilter(
                  key: const ValueKey('nsfw-blur-on'),
                  filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: Container(
                    color: effectiveTheme.scaffoldBackgroundColor.withValues(
                      alpha: effectiveTheme.cameraBlurTintOpacity,
                    ),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('nsfw-blur-off')),
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
    // background so the surrounding HUD still has the right colour.
    final fallbackTheme = widget.theme ?? NsfwGalleryTheme.defaults;
    return Container(color: fallbackTheme.scaffoldBackgroundColor);
  }

}
