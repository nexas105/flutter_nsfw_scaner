import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Models management screen (#34).
///
/// Lists every model returned by `NsfwDetector.availableModels()` and renders
/// a status pill plus download / remove / preload affordances. Live download
/// progress (bytes, ETA, speed) is computed from
/// `NsfwDetector.downloadProgress` and rendered as a [LinearProgressIndicator].
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key});

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  List<ModelDescriptor> _models = const [];
  bool _loading = true;
  String? _error;

  /// modelId → live progress snapshot used to draw the bar + ETA.
  final Map<String, _DownloadStat> _stats = {};

  /// Active download progress subscription. Multiplexes events for every
  /// model and updates [_stats] in place.
  StreamSubscription<ModelDownloadProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _progressSub = NsfwDetector.instance.downloadProgress.listen(_onProgress);
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  void _onProgress(ModelDownloadProgress p) {
    if (!mounted) return;
    final now = DateTime.now();
    final prev = _stats[p.modelId];
    final stat = _DownloadStat(
      fraction: p.fraction,
      bytesDownloaded: p.bytesDownloaded,
      totalBytes: p.totalBytes,
      isComplete: p.isComplete,
      error: p.error,
      startedAt: prev?.startedAt ?? now,
      lastEventAt: now,
      lastBytes: prev?.lastBytes ?? p.bytesDownloaded,
      bytesPerSecond: _computeRate(prev, p, now),
    );
    setState(() => _stats[p.modelId] = stat);
  }

  double? _computeRate(
      _DownloadStat? prev, ModelDownloadProgress p, DateTime now) {
    if (prev == null) return null;
    final dt = now.difference(prev.lastEventAt).inMilliseconds / 1000.0;
    if (dt <= 0) return prev.bytesPerSecond;
    final db = p.bytesDownloaded - prev.lastBytes;
    if (db <= 0) return prev.bytesPerSecond;
    return db / dt;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final models = await NsfwDetector.instance.availableModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _download(ModelDescriptor m) async {
    try {
      // Seed a 0% stat so the bar appears immediately, before the first event.
      setState(() => _stats[m.id] = _DownloadStat(
            fraction: 0,
            bytesDownloaded: 0,
            totalBytes: m.downloadSizeBytes > 0 ? m.downloadSizeBytes : null,
            isComplete: false,
            startedAt: DateTime.now(),
            lastEventAt: DateTime.now(),
            lastBytes: 0,
            bytesPerSecond: null,
          ));
      await NsfwDetector.instance.downloadModelWithProgress(m.id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final s = _stats[m.id];
        _stats[m.id] = (s ?? _emptyStat()).copyWith(error: e.toString());
      });
    }
  }

  Future<void> _remove(ModelDescriptor m) async {
    try {
      await NsfwDetector.instance.deleteModel(m.id);
      _stats.remove(m.id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remove failed: $e')),
      );
    }
  }

  Future<void> _preload(ModelDescriptor m) async {
    try {
      await NsfwDetector.instance.preloadModel(m.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preloaded ${m.displayName}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preload failed: $e')),
      );
    }
  }

  _DownloadStat _emptyStat() => _DownloadStat(
        fraction: 0,
        bytesDownloaded: 0,
        totalBytes: null,
        isComplete: false,
        startedAt: DateTime.now(),
        lastEventAt: DateTime.now(),
        lastBytes: 0,
        bytesPerSecond: null,
      );

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      backgroundColor: t.gallery.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Models'),
        backgroundColor: t.surface,
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!,
                        style: t.typography.caption.copyWith(color: t.danger),
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _models.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final m = _models[i];
                    return _ModelTile(
                      model: m,
                      stat: _stats[m.id],
                      onDownload: () => _download(m),
                      onRemove: () => _remove(m),
                      onPreload: () => _preload(m),
                      theme: t,
                    );
                  },
                ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final ModelDescriptor model;
  final _DownloadStat? stat;
  final VoidCallback onDownload;
  final VoidCallback onRemove;
  final VoidCallback onPreload;
  final NsfwTheme theme;

  const _ModelTile({
    required this.model,
    required this.stat,
    required this.onDownload,
    required this.onRemove,
    required this.onPreload,
    required this.theme,
  });

  bool get _isDownloading =>
      stat != null && !stat!.isComplete && stat!.error == null;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.displayName,
                          style: theme.typography.title
                              .copyWith(fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(model.id,
                          style: theme.typography.mono.copyWith(
                              color: theme.onSurfaceMuted, fontSize: 11)),
                      if (model.downloadSizeLabel.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text('${model.downloadSizeLabel} download',
                            style: theme.typography.caption),
                      ],
                    ],
                  ),
                ),
                _StatusPill(model: model, stat: stat, theme: theme),
              ],
            ),
            if (_isDownloading) ...[
              const SizedBox(height: 10),
              _ProgressBlock(stat: stat!, theme: theme),
            ],
            if (stat?.error != null) ...[
              const SizedBox(height: 8),
              Text('Error: ${stat!.error}',
                  style:
                      theme.typography.caption.copyWith(color: theme.danger)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (model.requiresDownload && !model.isDownloaded)
                  FilledButton.icon(
                    onPressed: _isDownloading ? null : onDownload,
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: Text(_isDownloading ? 'Downloading…' : 'Download'),
                  )
                else
                  FilledButton.tonalIcon(
                    onPressed: onPreload,
                    icon: const Icon(Icons.bolt_outlined, size: 16),
                    label: const Text('Preload'),
                  ),
                if (model.requiresDownload && model.isDownloaded)
                  OutlinedButton.icon(
                    onPressed: onRemove,
                    icon: Icon(Icons.delete_outline,
                        size: 16, color: theme.danger),
                    label: Text('Remove',
                        style: TextStyle(color: theme.danger)),
                  ),
              ],
            ),
          ],
        ),
      );
}

class _StatusPill extends StatelessWidget {
  final ModelDescriptor model;
  final _DownloadStat? stat;
  final NsfwTheme theme;
  const _StatusPill(
      {required this.model, required this.stat, required this.theme});

  ({String label, Color color}) _kind() {
    if (stat?.error != null) {
      return (label: 'Failed', color: theme.danger);
    }
    if (stat != null && !stat!.isComplete) {
      return (label: 'Downloading', color: theme.accent);
    }
    if (model.isDownloaded || !model.requiresDownload) {
      return (label: 'Loaded', color: theme.success);
    }
    if (model.downloadUrl != null || model.requiresDownload) {
      return (label: 'Available remote', color: theme.accent);
    }
    return (label: 'Not present', color: theme.onSurfaceMuted);
  }

  @override
  Widget build(BuildContext context) {
    final k = _kind();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: k.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        k.label,
        style: TextStyle(
          color: k.color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ProgressBlock extends StatelessWidget {
  final _DownloadStat stat;
  final NsfwTheme theme;
  const _ProgressBlock({required this.stat, required this.theme});

  String _eta() {
    final rate = stat.bytesPerSecond;
    final total = stat.totalBytes;
    if (rate == null || rate <= 0 || total == null) return '—';
    final remaining = total - stat.bytesDownloaded;
    if (remaining <= 0) return 'done';
    final secs = (remaining / rate).clamp(0, 60 * 60).toInt();
    if (secs >= 60) return '${(secs / 60).ceil()}m';
    return '${secs}s';
  }

  String _speedLabel() {
    final rate = stat.bytesPerSecond;
    if (rate == null || rate <= 0) return '—';
    if (rate >= 1024 * 1024) {
      return '${(rate / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (rate >= 1024) {
      return '${(rate / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${rate.toStringAsFixed(0)} B/s';
  }

  String _bytesLabel() {
    final total = stat.totalBytes;
    String fmt(int b) {
      if (b >= 1024 * 1024) {
        return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
      }
      if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
      return '$b B';
    }

    if (total != null && total > 0) {
      return '${fmt(stat.bytesDownloaded)} / ${fmt(total)}';
    }
    return fmt(stat.bytesDownloaded);
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: stat.fraction,
              minHeight: 6,
              backgroundColor: theme.surfaceVariant,
              valueColor: AlwaysStoppedAnimation(theme.accent),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '${(stat.fraction * 100).toStringAsFixed(0)}%',
                style: theme.typography.caption,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _bytesLabel(),
                  style: theme.typography.caption,
                ),
              ),
              Text('${_speedLabel()} • ETA ${_eta()}',
                  style: theme.typography.caption),
            ],
          ),
        ],
      );
}

class _DownloadStat {
  final double fraction;
  final int bytesDownloaded;
  final int? totalBytes;
  final bool isComplete;
  final String? error;
  final DateTime startedAt;
  final DateTime lastEventAt;
  final int lastBytes;
  final double? bytesPerSecond;

  const _DownloadStat({
    required this.fraction,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.isComplete,
    required this.startedAt,
    required this.lastEventAt,
    required this.lastBytes,
    required this.bytesPerSecond,
    this.error,
  });

  _DownloadStat copyWith({
    double? fraction,
    int? bytesDownloaded,
    int? totalBytes,
    bool? isComplete,
    String? error,
    DateTime? startedAt,
    DateTime? lastEventAt,
    int? lastBytes,
    double? bytesPerSecond,
  }) =>
      _DownloadStat(
        fraction: fraction ?? this.fraction,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        totalBytes: totalBytes ?? this.totalBytes,
        isComplete: isComplete ?? this.isComplete,
        error: error ?? this.error,
        startedAt: startedAt ?? this.startedAt,
        lastEventAt: lastEventAt ?? this.lastEventAt,
        lastBytes: lastBytes ?? this.lastBytes,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      );
}
