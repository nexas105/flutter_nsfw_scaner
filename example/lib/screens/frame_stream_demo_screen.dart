import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Whether the host plugin version exposes [FrameStreamScanner] /
/// `NsfwDetector.scanFrameStream`. Looked up at compile-time so the example
/// build doesn't break when an in-flight branch hasn't landed the symbol.
const bool kFrameStreamScannerAvailable =
    bool.fromEnvironment('nsfw_detect.frameStream', defaultValue: true);

/// Demonstrates the new live-frame scanner (#51). Picks a media file via
/// the bundled plugin picker and feeds its bytes into
/// [NsfwDetector.scanFrameStream] in a periodic synthetic stream.
///
/// Real apps will plug a camera- or WebRTC-driven `Stream<Uint8List>` here.
/// We replay the same bytes on a timer so the demo runs in the iOS / Android
/// simulators with no extra plugins.
class FrameStreamDemoScreen extends StatefulWidget {
  const FrameStreamDemoScreen({super.key});

  @override
  State<FrameStreamDemoScreen> createState() => _FrameStreamDemoScreenState();
}

class _FrameStreamDemoScreenState extends State<FrameStreamDemoScreen> {
  String? _filePath;
  Uint8List? _bytes;
  StreamController<Uint8List>? _frameController;
  FrameStreamScanner? _scanner;
  StreamSubscription<ScanResult>? _resultsSub;
  Timer? _ticker;
  final List<ScanResult> _results = [];
  bool _picking = false;
  bool _running = false;

  @override
  void dispose() {
    _resultsSub?.cancel();
    _ticker?.cancel();
    _scanner?.stop();
    _frameController?.close();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (!mounted) return;
      if (picked.isEmpty) {
        setState(() => _picking = false);
        return;
      }
      final p = picked.first;
      String? path = p.filePath;
      Uint8List? bytes;
      if (path != null) {
        bytes = await File(path).readAsBytes();
      }
      setState(() {
        _filePath = path;
        _bytes = bytes;
        _picking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _picking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pick failed: $e')),
      );
    }
  }

  Future<void> _start() async {
    if (_running) return;
    final bytes = _bytes;
    if (bytes == null) return;
    if (!kFrameStreamScannerAvailable) return;

    _frameController = StreamController<Uint8List>();
    _scanner = NsfwDetector.instance.scanFrameStream(
      frames: _frameController!.stream,
      targetFps: 2,
    );
    _resultsSub = _scanner!.results.listen((r) {
      if (!mounted) return;
      setState(() {
        _results.insert(0, r);
        if (_results.length > 20) _results.removeRange(20, _results.length);
      });
    });

    // Replay the same bytes 4× per second; targetFps=2 will drop half.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _frameController?.add(bytes);
    });
    setState(() => _running = true);
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    _ticker = null;
    await _resultsSub?.cancel();
    _resultsSub = null;
    await _scanner?.stop();
    _scanner = null;
    await _frameController?.close();
    _frameController = null;
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      appBar: AppBar(title: const Text('Frame Stream Scanner')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: !kFrameStreamScannerAvailable
            ? _Placeholder(
                title: 'FrameStreamScanner unavailable',
                body: 'This build of nsfw_detect does not yet export '
                    'FrameStreamScanner. Update to >= 2.3 to enable the demo.',
                theme: t,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Picks an image and replays it as a synthetic frame '
                    'stream at 4 fps. The scanner is throttled to targetFps: '
                    '2 — so roughly half the frames are dropped before '
                    'classification.',
                    style: t.typography.caption,
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    FilledButton.icon(
                      onPressed: _picking || _running ? null : _pick,
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(_picking ? 'Picking…' : 'Pick image'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _bytes == null || _running ? null : _start,
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('Start'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _running ? _stop : null,
                      icon: const Icon(Icons.stop_rounded, size: 16),
                      label: const Text('Stop'),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (_filePath != null)
                    Text('Source: ${_filePath!.split('/').last}',
                        style: t.typography.caption),
                  const Divider(height: 24),
                  Text('Live results',
                      style: t.typography.label),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _results.isEmpty
                        ? Center(
                            child: Text(
                              _running
                                  ? 'Waiting for first classification…'
                                  : 'No results yet — start a stream above.',
                              style: t.typography.caption,
                            ),
                          )
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (_, i) {
                              final r = _results[i];
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: r.isNsfw
                                      ? t.danger.withValues(alpha: 0.18)
                                      : t.surface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: t.outline),
                                ),
                                child: Row(children: [
                                  Icon(
                                    r.isNsfw
                                        ? Icons.warning_amber_rounded
                                        : Icons.check_circle_outline,
                                    color: r.isNsfw ? t.danger : t.success,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${r.topCategory.displayName} • '
                                      '${(r.topConfidence * 100).toStringAsFixed(0)}%'
                                      '${r.fromCache ? "  (cache)" : ""}',
                                      style: t.typography.mono,
                                    ),
                                  ),
                                ]),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String title;
  final String body;
  final NsfwTheme theme;
  const _Placeholder({
    required this.title,
    required this.body,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: theme.surface,
            border: Border.all(color: theme.outline),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.construction, color: theme.onSurfaceMuted, size: 32),
              const SizedBox(height: 8),
              Text(title, style: theme.typography.title),
              const SizedBox(height: 4),
              Text(body,
                  style: theme.typography.caption, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
