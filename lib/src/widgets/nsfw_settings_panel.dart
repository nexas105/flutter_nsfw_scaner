import 'dart:async';
import 'package:flutter/material.dart';
import '../api/model_descriptor.dart';
import '../api/model_download_progress.dart';
import '../api/nsfw_detector.dart';
import '../api/scan_configuration.dart';
import 'theme/nsfw_theme.dart';

/// Reusable settings panel that exposes the most common
/// [ScanConfiguration] knobs (model picker, scan options, maintenance
/// actions). Drop into any host scaffold — the widget is a `Column` of
/// sections, not a screen.
///
/// Pass [availableModels] to skip the internal model fetch (useful for tests
/// or when the host already has the list cached). [showMaintenance] hides the
/// reset / clear-cache section when set to false.
class NsfwSettingsPanel extends StatefulWidget {
  final ScanConfiguration current;
  final ValueChanged<ScanConfiguration> onChanged;
  final List<ModelDescriptor>? availableModels;
  final bool showMaintenance;
  final NsfwTheme? theme;

  const NsfwSettingsPanel({
    super.key,
    required this.current,
    required this.onChanged,
    this.availableModels,
    this.showMaintenance = true,
    this.theme,
  });

  @override
  State<NsfwSettingsPanel> createState() => _NsfwSettingsPanelState();
}

class _NsfwSettingsPanelState extends State<NsfwSettingsPanel> {
  List<ModelDescriptor> _models = [];
  bool _loadingModels = true;
  String? _downloadingModelId;
  bool _resettingScan = false;
  bool _clearingCache = false;

  final Map<String, ModelDownloadProgress> _downloadProgress = {};
  StreamSubscription<ModelDownloadProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    if (widget.availableModels != null) {
      _models = widget.availableModels!;
      _loadingModels = false;
    } else {
      _loadModels();
    }
    _progressSub = NsfwDetector.instance.downloadProgress.listen((p) {
      if (!mounted) return;
      setState(() => _downloadProgress[p.modelId] = p);
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final models = await NsfwDetector.instance.availableModels();
      if (mounted) {
        setState(() {
          _models = models;
          _loadingModels = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _emit(ScanConfiguration next) {
    widget.onChanged(next);
    setState(() {});
  }

  ScanConfiguration get _config => widget.current;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme ?? NsfwTheme.defaults();
    final s = t.spacing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(theme: t, label: 'Detection Model'),
        _modelPicker(t),
        SizedBox(height: s.xl),
        _SectionHeader(theme: t, label: 'Scan Options'),
        _scanOptions(t),
        if (widget.showMaintenance) ...[
          SizedBox(height: s.xl),
          _SectionHeader(theme: t, label: 'Maintenance'),
          _maintenanceActions(t),
        ],
      ],
    );
  }

  Widget _card(NsfwTheme t, Widget child) => Container(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(t.spacing.md),
        ),
        child: child,
      );

  // ── Model picker ──────────────────────────────────────────────────────────

  Widget _modelPicker(NsfwTheme t) => _card(
        t,
        _loadingModels
            ? Padding(
                padding: EdgeInsets.all(t.spacing.lg),
                child: const Center(child: CircularProgressIndicator()),
              )
            : RadioGroup<String>(
                groupValue: _config.modelId,
                onChanged: (v) {
                  final model = _models.where((m) => m.id == v).firstOrNull;
                  if (model != null && model.isAvailable) {
                    _emit(_config.copyWith(modelId: v));
                  }
                },
                child: Column(
                  children: _models.map((m) => _modelTile(t, m)).toList(),
                ),
              ),
      );

  Widget _modelTile(NsfwTheme t, ModelDescriptor m) {
    final needsDownload = m.requiresDownload && !m.isDownloaded;
    final isDownloading = _downloadingModelId == m.id;
    final progress = _downloadProgress[m.id];
    final showProgressBar =
        isDownloading && progress != null && !progress.isComplete;

    return ListTile(
      leading: Radio<String>(value: m.id),
      title: Row(
        children: [
          Expanded(
            child: Text(
              m.displayName,
              style: t.typography.body.copyWith(
                color: needsDownload ? t.onSurfaceMuted : t.onSurface,
              ),
            ),
          ),
          if (needsDownload && !isDownloading)
            GestureDetector(
              onTap: () => _downloadModel(m),
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: t.spacing.sm, vertical: t.spacing.xs),
                decoration: BoxDecoration(
                  color: t.accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  m.downloadSizeBytes > 0
                      ? 'Download (${m.downloadSizeLabel})'
                      : 'Download',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          if (isDownloading && !showProgressBar)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (m.requiresDownload && m.isDownloaded && !isDownloading)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: t.success, size: 18),
                SizedBox(width: t.spacing.xs),
                GestureDetector(
                  onTap: () => _redownloadModel(m),
                  child: Icon(Icons.refresh,
                      color: t.onSurfaceMuted, size: 18),
                ),
              ],
            ),
        ],
      ),
      subtitle: showProgressBar
          ? Padding(
              padding: EdgeInsets.only(top: t.spacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress.fraction,
                      minHeight: 6,
                      backgroundColor: t.accent.withValues(alpha: 0.15),
                      valueColor: AlwaysStoppedAnimation(t.accent),
                    ),
                  ),
                  SizedBox(height: t.spacing.xs),
                  Text(
                    '${(progress.fraction * 100).toStringAsFixed(0)}% — '
                    '${progress.bytesLabel}',
                    style: t.typography.caption,
                  ),
                ],
              ),
            )
          : (m.description != null
              ? Text(m.description!, style: t.typography.caption)
              : null),
    );
  }

  Future<void> _redownloadModel(ModelDescriptor m) async {
    setState(() => _downloadingModelId = m.id);
    try {
      await NsfwDetector.instance.deleteModel(m.id);
      await NsfwDetector.instance.downloadModel(m.id, url: m.downloadUrl);
      await _loadModels();
      if (mounted) {
        _emit(_config.copyWith(modelId: m.id));
        setState(() => _downloadingModelId = null);
        _snack('${m.displayName} updated.', success: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadingModelId = null);
        _snack('Re-download failed: $e', success: false);
      }
    }
  }

  Future<void> _downloadModel(ModelDescriptor m) async {
    if (m.downloadUrl == null || m.downloadUrl!.isEmpty) {
      _snack('No download URL configured for ${m.displayName}.', success: false);
      return;
    }
    setState(() => _downloadingModelId = m.id);
    try {
      await NsfwDetector.instance.downloadModel(m.id, url: m.downloadUrl);
      await _loadModels();
      if (mounted) {
        _emit(_config.copyWith(modelId: m.id));
        setState(() => _downloadingModelId = null);
        _snack('${m.displayName} downloaded.', success: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadingModelId = null);
        _snack('Download failed: $e', success: false);
      }
    }
  }

  // ── Scan options ──────────────────────────────────────────────────────────

  Widget _scanOptions(NsfwTheme t) => _card(
        t,
        Column(
          children: [
            _sliderTile(
              t,
              title: 'Confidence Threshold',
              valueLabel: '${(_config.confidenceThreshold * 100).round()}%',
              subtitle: 'Items above this are marked NSFW',
              value: _config.confidenceThreshold,
              min: 0.3,
              max: 0.99,
              divisions: 69,
              onChanged: (v) => _emit(_config.copyWith(confidenceThreshold: v)),
            ),
            _divider(t),
            _sliderTile(
              t,
              title: 'Max Video Frames',
              valueLabel: '${_config.maxVideoFrames}',
              subtitle: 'Frames sampled per video',
              value: _config.maxVideoFrames.toDouble(),
              min: 2,
              max: 20,
              divisions: 18,
              onChanged: (v) =>
                  _emit(_config.copyWith(maxVideoFrames: v.round())),
            ),
            _divider(t),
            _sliderTile(
              t,
              title: 'Concurrency',
              valueLabel: '${_config.concurrency}',
              subtitle: 'Parallel scan tasks',
              value: _config.concurrency.toDouble(),
              min: 1,
              max: 8,
              divisions: 7,
              onChanged: (v) =>
                  _emit(_config.copyWith(concurrency: v.round())),
            ),
            _divider(t),
            _switchTile(
              t,
              title: 'Include Videos',
              value: _config.includeVideos,
              onChanged: (v) => _emit(_config.copyWith(includeVideos: v)),
            ),
            _divider(t),
            _switchTile(
              t,
              title: 'Include Live Photos',
              value: _config.includeLivePhotos,
              onChanged: (v) =>
                  _emit(_config.copyWith(includeLivePhotos: v)),
            ),
            _divider(t),
            _switchTile(
              t,
              title: 'Resume from Checkpoint',
              subtitle: 'Continue where last scan left off',
              value: _config.resumeFromCheckpoint,
              onChanged: (v) =>
                  _emit(_config.copyWith(resumeFromCheckpoint: v)),
            ),
            _divider(t),
            _switchTile(
              t,
              title: 'Skip Already Scanned',
              subtitle: 'Re-syncs reuse cached results',
              value: _config.skipAlreadyScanned,
              onChanged: (v) =>
                  _emit(_config.copyWith(skipAlreadyScanned: v)),
            ),
            _divider(t),
            _switchTile(
              t,
              title: 'Force Rescan',
              subtitle: 'Bypass cache for this run',
              value: _config.forceRescan,
              onChanged: (v) => _emit(_config.copyWith(forceRescan: v)),
            ),
          ],
        ),
      );

  Widget _sliderTile(
    NsfwTheme t, {
    required String title,
    required String valueLabel,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) =>
      ListTile(
        title: Text(title, style: t.typography.body.copyWith(color: t.onSurface)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              activeColor: t.accent,
              onChanged: onChanged,
            ),
            Text('$valueLabel — $subtitle', style: t.typography.caption),
          ],
        ),
      );

  Widget _switchTile(
    NsfwTheme t, {
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        title: Text(title, style: t.typography.body.copyWith(color: t.onSurface)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: t.typography.caption),
        value: value,
        activeTrackColor: t.accent,
        onChanged: onChanged,
      );

  Widget _divider(NsfwTheme t) => Divider(color: t.outline, height: 1);

  // ── Maintenance ──────────────────────────────────────────────────────────

  Widget _maintenanceActions(NsfwTheme t) => _card(
        t,
        Column(
          children: [
            ListTile(
              leading: Icon(Icons.restart_alt_rounded, color: t.onSurfaceMuted),
              title: Text(
                'Reset Native Scan State',
                style: t.typography.body.copyWith(color: t.onSurface),
              ),
              subtitle: Text('Calls NsfwDetector.resetScan()',
                  style: t.typography.caption),
              trailing: FilledButton(
                onPressed: _resettingScan ? null : _resetScanState,
                style: FilledButton.styleFrom(backgroundColor: t.accent),
                child: _resettingScan
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Run'),
              ),
            ),
            _divider(t),
            ListTile(
              leading: Icon(Icons.delete_sweep_outlined, color: t.onSurfaceMuted),
              title: Text(
                'Clear Scan Cache',
                style: t.typography.body.copyWith(color: t.onSurface),
              ),
              subtitle: Text(
                'Drops all cached classifications.',
                style: t.typography.caption,
              ),
              trailing: FilledButton(
                onPressed: _clearingCache ? null : _clearScanCache,
                style: FilledButton.styleFrom(backgroundColor: t.danger),
                child: _clearingCache
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Clear'),
              ),
            ),
          ],
        ),
      );

  Future<void> _resetScanState() async {
    if (_resettingScan) return;
    setState(() => _resettingScan = true);
    try {
      await NsfwDetector.instance.resetScan();
      if (mounted) _snack('Native scan state reset complete.', success: true);
    } catch (e) {
      if (mounted) _snack('Reset failed: $e', success: false);
    } finally {
      if (mounted) setState(() => _resettingScan = false);
    }
  }

  Future<void> _clearScanCache() async {
    if (_clearingCache) return;
    setState(() => _clearingCache = true);
    try {
      await NsfwDetector.instance.clearScanCache();
      if (mounted) {
        _snack('Scan cache cleared. Next scan will reclassify.',
            success: true);
      }
    } catch (e) {
      if (mounted) _snack('Clear cache failed: $e', success: false);
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  void _snack(String message, {required bool success}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green.shade700 : Colors.red.shade700,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final NsfwTheme theme;
  final String label;
  const _SectionHeader({required this.theme, required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: theme.spacing.sm),
        child: Text(label.toUpperCase(), style: theme.typography.label),
      );
}
