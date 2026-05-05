import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';
import '../state/app_settings.dart';

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
  // ignore: unused_field — read by feature commits TEST-03/04 (HUD log).
  CameraFrameResult? _lastResult;
  // ignore: unused_field — read by feature commits TEST-03/04 (error tile).
  Object? _lastError;

  // Force a full remount of NsfwCameraView when configuration changes
  // so the underlying CameraScanSession is recreated (fresh start).
  // Bumping this key while _running == true causes Flutter to dispose
  // the previous widget (which calls stopCameraScan) and instantiate a
  // new one (which calls startCameraScan).
  int _viewKey = 0;

  // Model picker state — populated lazily from
  // NsfwDetector.instance.availableModels() (same source as the
  // NsfwSettingsPanel in SettingsScreen / GalleryScreen).
  List<ModelDescriptor> _models = const [];
  String? _modelId;
  ScanMode _mode = ScanMode.classification;
  bool _settingsHydrated = false;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settingsHydrated) return;
    final s = AppSettingsScope.of(context);
    _modelId = s.cameraModelId;
    _mode = s.cameraMode;
    _settingsHydrated = true;
  }

  Future<void> _loadModels() async {
    try {
      final list = await NsfwDetector.instance.availableModels();
      if (!mounted) return;
      setState(() {
        _models = list;
        // If the persisted modelId is unknown (e.g. a model was removed
        // between sessions), fall back to the first available.
        final known = list.any((m) => m.id == _modelId);
        if (!known && list.isNotEmpty) {
          _modelId = list.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastError = 'availableModels failed: $e');
    }
  }

  CameraConfiguration _currentConfig() => CameraConfiguration(
        modelId: _modelId ?? ModelIds.openNsfw2,
        mode: _mode,
      );

  Future<void> _restartIfRunning() async {
    if (!_running) return;
    // Briefly drop the view so its dispose() resolves (which invokes
    // stopCameraScan) before we mount the next one. A single frame
    // off-screen is enough for the platform side to drain.
    setState(() => _running = false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    setState(() {
      _viewKey += 1;
      _running = true;
      _lastResult = null;
    });
  }

  Future<void> _onModelChanged(String? newId) async {
    if (newId == null || newId == _modelId) return;
    final settings = AppSettingsScope.of(context);
    setState(() => _modelId = newId);
    settings.cameraModelId = newId;
    await _restartIfRunning();
  }

  Future<void> _onModeChanged(ScanMode newMode) async {
    if (newMode == _mode) return;
    final settings = AppSettingsScope.of(context);
    setState(() => _mode = newMode);
    settings.cameraMode = newMode;
    await _restartIfRunning();
  }

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
        actions: [
          if (_models.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: t.spacing.sm),
              child: _ModelMenu(
                models: _models,
                selectedId: _modelId,
                onSelected: _onModelChanged,
                theme: t,
              ),
            ),
        ],
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
              mode: _mode,
              onStart: _start,
              onStop: _stop,
              onModeChanged: _onModeChanged,
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
  final ScanMode mode;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<ScanMode> onModeChanged;
  final NsfwTheme theme;

  const _CameraControlsBar({
    required this.running,
    required this.mode,
    required this.onStart,
    required this.onStop,
    required this.onModeChanged,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
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
            SizedBox(height: t.spacing.sm),
            // Mode toggle. Switching mode mid-session triggers a clean
            // restart of the underlying CameraScanSession via the
            // screen's _onModeChanged → _restartIfRunning() chain.
            SegmentedButton<ScanMode>(
              segments: const [
                ButtonSegment(
                  value: ScanMode.classification,
                  label: Text('Classify'),
                  icon: Icon(Icons.tune_rounded),
                ),
                ButtonSegment(
                  value: ScanMode.detection,
                  label: Text('Detect'),
                  icon: Icon(Icons.crop_free_rounded),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => onModeChanged(s.first),
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return t.accent.withValues(alpha: 0.18);
                  }
                  return t.surfaceVariant;
                }),
                foregroundColor: WidgetStateProperty.all(t.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelMenu extends StatelessWidget {
  final List<ModelDescriptor> models;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final NsfwTheme theme;

  const _ModelMenu({
    required this.models,
    required this.selectedId,
    required this.onSelected,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final selected = models.firstWhere(
      (m) => m.id == selectedId,
      orElse: () => models.first,
    );
    return PopupMenuButton<String>(
      tooltip: 'Choose model',
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final m in models)
          PopupMenuItem<String>(
            value: m.id,
            child: Row(
              children: [
                Icon(
                  m.id == selectedId
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: m.id == selectedId
                      ? theme.accent
                      : theme.onSurfaceMuted,
                ),
                SizedBox(width: theme.spacing.sm),
                Flexible(child: Text(m.displayName)),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacing.sm,
          vertical: theme.spacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bubble_chart_outlined,
                size: 18, color: theme.onSurface),
            SizedBox(width: theme.spacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                selected.displayName,
                style: theme.typography.label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}
