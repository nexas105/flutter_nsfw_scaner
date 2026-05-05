import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../api/camera_configuration.dart';
import '../api/camera_frame_result.dart';
import '../api/camera_scan_session.dart';
import '../api/camera_exceptions.dart';
import '../api/nsfw_detector.dart';
import 'nsfw_result_badge.dart';
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
        // TODO(platform-view): Replace with UiKitView/AndroidView for native camera preview.
        Container(color: Colors.black),

        // Optional blur overlay
        if (isBlurred)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
            child: Container(color: Colors.black.withValues(alpha: 0.2)),
          ),

        // HUD overlay
        if (widget.showHudOverlay && _lastResult != null)
          _buildHudOverlay(),
      ],
    );
  }

  Widget _buildHudOverlay() {
    final result = _lastResult!;
    final effectiveTheme = widget.theme ?? NsfwGalleryTheme.defaults;

    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Confidence bar
          LinearProgressIndicator(
            value: result.topConfidence,
            backgroundColor: effectiveTheme.safeColor.withValues(alpha: 0.3),
            valueColor: AlwaysStoppedAnimation<Color>(
              result.isNsfw ? effectiveTheme.nsfwColor : effectiveTheme.safeColor,
            ),
            minHeight: 4,
          ),
          const SizedBox(height: 4),
          // Category badge
          NsfwResultBadge(
            result: null, // null = scanning animation
            style: BadgeStyle.compact,
            theme: effectiveTheme,
          ),
        ],
      ),
    );
  }
}
