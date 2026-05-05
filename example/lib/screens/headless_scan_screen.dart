import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import '../main.dart';

/// Demonstrates using the nsfw_detect plugin as a pure Dart API —
/// no NsfwGalleryView widget, no built-in UI. Everything is wired manually.
///
/// **This is the raw API on purpose.** In production code you would normally
/// reach for [NsfwScanController] which already encapsulates the session
/// lifecycle, results buffer and progress stream behind a [ChangeNotifier].
/// This screen exists to show what that controller does under the hood —
/// the setState / StreamSubscription dance below is exactly what
/// [NsfwScanController] hides for you.
class HeadlessScanScreen extends StatefulWidget {
  const HeadlessScanScreen({super.key});

  @override
  State<HeadlessScanScreen> createState() => _HeadlessScanScreenState();
}

class _HeadlessScanScreenState extends State<HeadlessScanScreen> {
  ScanSession? _session;
  ScanProgress? _progress;
  final List<_LogEntry> _log = [];
  bool _running = false;

  static const _config = ScanConfiguration(
    confidenceThreshold: 0.65,
    includeVideos: false,
    concurrency: 3,
  );

  @override
  void dispose() {
    _session?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_running) return;

    setState(() {
      _log.clear();
      _progress = null;
      _running = true;
    });
    _addLog('Checking permission…', _LogLevel.info);

    final status = await NsfwDetector.instance.requestPermission();
    _addLog('Permission: ${status.name}', _LogLevel.info);

    if (status != PhotoLibraryPermissionStatus.authorized &&
        status != PhotoLibraryPermissionStatus.limited) {
      _addLog('Scan aborted — permission required.', _LogLevel.error);
      setState(() => _running = false);
      return;
    }

    _addLog('Starting scan (threshold ${_config.confidenceThreshold * 100 ~/ 1}%, '
        '${_config.concurrency} concurrent)…', _LogLevel.info);

    final session = await NsfwDetector.instance.startScan(_config);
    setState(() => _session = session);

    session.results.listen(
      (result) {
        if (!mounted) return;
        if (result.isNsfw) {
          _addLog(
            'NSFW  ${_shortId(result.item.localIdentifier)}  '
            '${result.topCategory.displayName} '
            '${(result.topConfidence * 100).toStringAsFixed(0)}%',
            _LogLevel.nsfw,
          );
        } else if (_log.where((e) => e.level == _LogLevel.safe).length % 50 ==
            49) {
          _addLog(
            'safe  ${_shortId(result.item.localIdentifier)}',
            _LogLevel.safe,
          );
        }
      },
    );

    session.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });

    final summary = await session.done;
    if (!mounted) return;

    _addLog(
      'Done — ${summary.totalScanned} scanned, '
      '${summary.nsfwCount} NSFW, '
      '${summary.skippedCount} skipped, '
      '${summary.elapsed.inSeconds}s',
      _LogLevel.info,
    );
    setState(() => _running = false);
  }

  Future<void> _cancelScan() async {
    await _session?.cancel();
    if (mounted) {
      _addLog('Scan cancelled by user.', _LogLevel.info);
      setState(() => _running = false);
    }
  }

  void _addLog(String message, _LogLevel level) {
    if (!mounted) return;
    setState(() => _log.insert(0, _LogEntry(message, level)));
  }

  String _shortId(String id) {
    if (id.length <= 18) return id;
    return '${id.substring(0, 8)}…${id.substring(id.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = appNsfwTheme;
    final progress = _progress;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Headless API Demo'),
        backgroundColor: t.surface,
        actions: [
          if (_running)
            Padding(
              padding: EdgeInsets.only(right: t.spacing.md),
              child: TextButton.icon(
                onPressed: _cancelScan,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Cancel'),
                style: TextButton.styleFrom(foregroundColor: t.danger),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _ConfigCard(config: _config, theme: t),
          if (progress != null) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(t.spacing.lg, 0, t.spacing.lg, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress.fraction,
                      minHeight: 6,
                      backgroundColor: t.surfaceVariant,
                      valueColor: AlwaysStoppedAnimation(
                        progress.isComplete ? t.success : t.accent,
                      ),
                    ),
                  ),
                  SizedBox(height: t.spacing.xs),
                  Text(
                    '${progress.scannedCount} / ${progress.totalCount}  '
                    '(${(progress.fraction * 100).toStringAsFixed(0)}%)',
                    style: t.typography.caption,
                  ),
                ],
              ),
            ),
            SizedBox(height: t.spacing.sm),
          ],
          if (!_running)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  t.spacing.lg, t.spacing.sm, t.spacing.lg, t.spacing.sm),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Start Scan'),
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    padding: EdgeInsets.symmetric(vertical: t.spacing.md + 2),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                t.spacing.lg, 0, t.spacing.lg, t.spacing.xs),
            child: Row(children: [
              Text('EVENT LOG', style: t.typography.label),
              SizedBox(width: t.spacing.sm),
              Text('${_log.length} events',
                  style: t.typography.caption.copyWith(fontSize: 10)),
            ]),
          ),
          Expanded(
            child: _log.isEmpty
                ? Center(
                    child: Text(
                      'Events will appear here',
                      style: t.typography.caption,
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                        t.spacing.md, 0, t.spacing.md, t.spacing.lg),
                    itemCount: _log.length,
                    itemBuilder: (_, i) =>
                        _LogTile(entry: _log[i], theme: t),
                  ),
          ),
        ],
      ),
    );
  }
}

enum _LogLevel { info, nsfw, safe, error }

class _LogEntry {
  final String message;
  final _LogLevel level;
  final DateTime ts;
  _LogEntry(this.message, this.level) : ts = DateTime.now();
}

class _LogTile extends StatelessWidget {
  final _LogEntry entry;
  final NsfwTheme theme;
  const _LogTile({required this.entry, required this.theme});

  Color _color() => switch (entry.level) {
        _LogLevel.nsfw => theme.gallery.nsfwColor,
        _LogLevel.safe => theme.gallery.safeColor,
        _LogLevel.error => theme.gallery.suggestiveColor,
        _LogLevel.info => theme.onSurfaceMuted,
      };

  @override
  Widget build(BuildContext context) {
    final ts = entry.ts;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${ts.hour.toString().padLeft(2, '0')}:'
            '${ts.minute.toString().padLeft(2, '0')}:'
            '${ts.second.toString().padLeft(2, '0')}',
            style: theme.typography.mono.copyWith(
              fontSize: 10,
              color: theme.onSurfaceMuted.withValues(alpha: 0.7),
            ),
          ),
          SizedBox(width: theme.spacing.sm),
          Expanded(
            child: Text(
              entry.message,
              style: theme.typography.mono.copyWith(color: _color()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  final ScanConfiguration config;
  final NsfwTheme theme;
  const _ConfigCard({required this.config, required this.theme});

  @override
  Widget build(BuildContext context) => Container(
        margin: EdgeInsets.all(theme.spacing.lg),
        padding: EdgeInsets.all(theme.spacing.md + 2),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(theme.spacing.md),
          border: Border.all(color: theme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ScanConfiguration', style: theme.typography.label),
            SizedBox(height: theme.spacing.sm),
            _Row(
              key_: 'confidenceThreshold',
              value: '${(config.confidenceThreshold * 100).toStringAsFixed(0)}%',
              theme: theme,
            ),
            _Row(
              key_: 'includeVideos',
              value: '${config.includeVideos}',
              theme: theme,
            ),
            _Row(
              key_: 'concurrency',
              value: '${config.concurrency}',
              theme: theme,
            ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  final String key_;
  final String value;
  final NsfwTheme theme;
  const _Row({required this.key_, required this.value, required this.theme});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text('$key_: ',
              style: theme.typography.mono.copyWith(color: theme.onSurfaceMuted)),
          Text(value,
              style: theme.typography.mono
                  .copyWith(color: Colors.lightBlueAccent.shade100)),
        ]),
      );
}
