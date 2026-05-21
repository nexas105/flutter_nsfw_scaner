import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Demonstrates error-recovery UX for the four most common failure modes:
///   1. Photo-library permission denied → deep-link to system Settings.
///   2. Camera permission denied → deep-link to system Settings.
///   3. Model unavailable on device → retry `ensureReady` or pick alternate.
///   4. Network offline while downloading → cancel + retry guidance.
///
/// Each card carries a "Recover" button wired to the most-likely fix; this
/// is a UX showcase, not a real diagnostics tool — the real plugin surfaces
/// these states via `NsfwInitReport.errors`, `PermissionStatus`, and the
/// `ModelDownloadProgress.error` field.
class ErrorStatesScreen extends StatefulWidget {
  const ErrorStatesScreen({super.key});

  @override
  State<ErrorStatesScreen> createState() => _ErrorStatesScreenState();
}

class _ErrorStatesScreenState extends State<ErrorStatesScreen> {
  PhotoLibraryPermissionStatus? _libStatus;
  PermissionStatus? _cameraStatus;
  String? _lastAction;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final lib = await NsfwDetector.instance.checkPermission();
    final cam = await NsfwDetector.instance.checkCameraPermission();
    if (!mounted) return;
    setState(() {
      _libStatus = lib;
      _cameraStatus = cam;
    });
  }

  Future<void> _requestPhotoLibrary() async {
    final status = await NsfwDetector.instance.requestPermission();
    if (!mounted) return;
    setState(() {
      _libStatus = status;
      _lastAction = 'Photo library: ${status.name}';
    });
  }

  Future<void> _requestCamera() async {
    final status = await NsfwDetector.instance.requestCameraPermission();
    if (!mounted) return;
    setState(() {
      _cameraStatus = status;
      _lastAction = 'Camera: ${status.name}';
    });
  }

  Future<void> _openAppSettings() async {
    await AppSettings.openAppSettings();
    if (!mounted) return;
    setState(() => _lastAction = 'Opened system Settings');
  }

  Future<void> _retryModel() async {
    try {
      await NsfwDetector.instance.models.ensureReady(ModelIds.openNsfw2);
      if (!mounted) return;
      setState(() => _lastAction = 'Model ready: ${ModelIds.openNsfw2}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastAction = 'Model load failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      backgroundColor: t.gallery.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Error Recovery'),
        backgroundColor: t.surface,
        actions: [
          IconButton(
            tooltip: 'Refresh statuses',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_lastAction != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.success.withValues(alpha: 0.12),
                  border:
                      Border.all(color: t.success.withValues(alpha: 0.45)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_lastAction!,
                    style: t.typography.caption.copyWith(color: t.success)),
              ),
            ),
          _StateCard(
            icon: Icons.photo_library_outlined,
            tint: t.danger,
            title: 'Photo-library access denied',
            description:
                'Status: ${_libStatus?.name ?? '…'}. When the user denies '
                'access we can re-prompt only while the OS still allows it. '
                'After a hard denial the only path is the system Settings.',
            primaryLabel: _libStatus?.needsSettingsApp ?? false
                ? 'Open Settings'
                : 'Request again',
            onPrimary: _libStatus?.needsSettingsApp ?? false
                ? _openAppSettings
                : _requestPhotoLibrary,
            theme: t,
          ),
          _StateCard(
            icon: Icons.camera_alt_outlined,
            tint: t.danger,
            title: 'Camera permission denied',
            description: 'Status: ${_cameraStatus?.name ?? '…'}. Live scanning '
                'and any in-app capture flow needs this grant.',
            primaryLabel: _cameraStatus?.needsSettings ?? false
                ? 'Open Settings'
                : 'Request camera',
            onPrimary: _cameraStatus?.needsSettings ?? false
                ? _openAppSettings
                : _requestCamera,
            theme: t,
          ),
          _StateCard(
            icon: Icons.cloud_off_outlined,
            tint: t.gallery.suggestiveColor,
            title: 'Model unavailable on device',
            description:
                'A downloadable model (e.g. NudeNet) has not been fetched '
                'yet. Tap to retry — this calls `models.ensureReady(id)` '
                'which downloads + warms the model atomically.',
            primaryLabel: 'Retry ensureReady',
            onPrimary: _retryModel,
            theme: t,
          ),
          _StateCard(
            icon: Icons.signal_wifi_off_outlined,
            tint: t.gallery.suggestiveColor,
            title: 'Network dropped during download',
            description:
                'When `downloadProgress` emits an event with `error != null`, '
                'cancel the current download and surface a retry. The Models '
                'screen demonstrates the live progress + retry pattern.',
            primaryLabel: 'Go to Models',
            onPrimary: () => Navigator.of(context).maybePop(),
            theme: t,
          ),
        ],
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String description;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final NsfwTheme theme;

  const _StateCard({
    required this.icon,
    required this.tint,
    required this.title,
    required this.description,
    required this.primaryLabel,
    required this.onPrimary,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: tint),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: theme.typography.title.copyWith(fontSize: 15)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(description, style: theme.typography.caption),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  onPressed: onPrimary,
                  child: Text(primaryLabel),
                ),
              ],
            ),
          ],
        ),
      );
}
