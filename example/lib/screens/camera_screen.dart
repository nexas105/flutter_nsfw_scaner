import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Live camera-scan demo screen — a peer of [GalleryScreen],
/// [PickerScreen], and [HeadlessScanScreen].
///
/// Lifecycle ownership note (per Phase-05 PLAN, "Note on NsfwCameraView
/// ownership of the session"): this screen takes the **fallback**
/// approach — it does not own the [CameraScanSession] itself. Instead,
/// when [_running] is true the screen mounts a single [NsfwCameraView]
/// which owns its own session via `initState` / `dispose`. Switching
/// model or mode (later commits) unmounts the widget (clean stop) and
/// remounts it with fresh creation params (clean start). One session
/// at a time, no concurrent-session [StateError] risk.
///
/// Mirrors the controls bar pattern from [HeadlessScanScreen]: a single
/// `_running` flag toggles UI without coupling lifecycle to any child.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _running = false;
  // ignore: unused_field — read by feature commits TEST-02/03/04 (HUD log).
  CameraFrameResult? _lastResult;
  // ignore: unused_field — read by feature commits TEST-02/03/04 (error tile).
  Object? _lastError;

  // Force a full remount of NsfwCameraView when configuration changes
  // so the underlying CameraScanSession is recreated (fresh start).
  // Bumping this key while _running == true causes Flutter to dispose
  // the previous widget (which calls stopCameraScan) and instantiate a
  // new one (which calls startCameraScan).
  int _viewKey = 0;

  CameraConfiguration _currentConfig() => const CameraConfiguration();

  void _start() {
    if (_running) return;
    setState(() {
      _running = true;
      _lastError = null;
      _lastResult = null;
      _viewKey += 1;
    });
  }

  void _stop() {
    if (!_running) return;
    setState(() {
      _running = false;
      _lastResult = null;
    });
  }

  void _onResult(CameraFrameResult r) {
    if (!mounted) return;
    setState(() => _lastResult = r);
  }

  void _onError(Object e) {
    if (!mounted) return;
    setState(() => _lastError = e);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text('Camera error: $e'),
      backgroundColor: appNsfwTheme.danger,
    ));
  }

  void _onPermissionDenied() {
    if (!mounted) return;
    setState(() {
      _running = false;
      _lastError = 'Camera permission denied.';
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: const Text(
        'Camera permission denied. Enable it in Settings to scan live.',
      ),
      backgroundColor: appNsfwTheme.danger,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = appNsfwTheme;
    return Scaffold(
      backgroundColor: t.gallery.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'Camera Scan',
          style: t.typography.title.copyWith(fontSize: 18),
        ),
        backgroundColor: t.surface,
      ),
      body: Stack(
        children: [
          if (_running)
            Positioned.fill(
              child: NsfwCameraView(
                key: ValueKey(_viewKey),
                config: _currentConfig(),
                onResult: _onResult,
                onError: _onError,
                onPermissionDenied: _onPermissionDenied,
                theme: t.gallery,
              ),
            )
          else
            const _CameraIdlePanel(),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _CameraControlsBar(
              running: _running,
              onStart: _start,
              onStop: _stop,
              theme: t,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraIdlePanel extends StatelessWidget {
  const _CameraIdlePanel();

  @override
  Widget build(BuildContext context) {
    final t = appNsfwTheme;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined,
                size: 64, color: t.onSurfaceMuted),
            SizedBox(height: t.spacing.md),
            Text(
              'Camera idle',
              style: t.typography.title.copyWith(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: t.spacing.sm),
            Text(
              'Press Start below to begin a live scan. The selected model '
              'will classify each frame on-device at the configured FPS.',
              style: t.typography.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraControlsBar extends StatelessWidget {
  final bool running;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final NsfwTheme theme;

  const _CameraControlsBar({
    required this.running,
    required this.onStart,
    required this.onStop,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.all(t.spacing.md),
        padding: EdgeInsets.all(t.spacing.md),
        decoration: BoxDecoration(
          color: t.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(t.spacing.md),
          border: Border.all(color: t.outline),
          boxShadow: t.elevation.mid,
        ),
        child: Row(
          children: [
            Expanded(
              child: running
                  ? FilledButton.icon(
                      onPressed: onStop,
                      icon: const Icon(Icons.stop_rounded, size: 20),
                      label: const Text('Stop'),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.danger,
                        padding: EdgeInsets.symmetric(
                            vertical: t.spacing.md),
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: onStart,
                      icon: const Icon(
                          Icons.play_arrow_rounded, size: 20),
                      label: const Text('Start'),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        padding: EdgeInsets.symmetric(
                            vertical: t.spacing.md),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
