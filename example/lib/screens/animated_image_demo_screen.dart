import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Demonstrates scanning animated images — GIFs and animated WebPs (#53).
///
/// The plugin samples every Nth frame on the native side and rolls the per-
/// frame scores into a single [ScanResult]. When the underlying map carries
/// a `frameCount` field we surface it as "Scanned N frames".
class AnimatedImageDemoScreen extends StatefulWidget {
  const AnimatedImageDemoScreen({super.key});

  @override
  State<AnimatedImageDemoScreen> createState() =>
      _AnimatedImageDemoScreenState();
}

class _AnimatedImageDemoScreenState extends State<AnimatedImageDemoScreen> {
  String? _filePath;
  ScanResult? _result;
  int? _frameCount;
  String? _error;
  bool _busy = false;

  Future<void> _pickAndScan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _frameCount = null;
    });
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (!mounted) return;
      if (picked.isEmpty) {
        setState(() => _busy = false);
        return;
      }
      final path = picked.first.filePath;
      if (path == null) {
        setState(() {
          _error = 'Picker did not return a file path.';
          _busy = false;
        });
        return;
      }
      final result = await NsfwDetector.instance.scanFile(path);
      // Best-effort: `frameCount` may be present on the underlying map for
      // animated samplers. ScanResult round-trips through toMap() so we can
      // inspect it without a typed accessor.
      final m = result.toMap();
      final fc = m['frameCount'];
      if (!mounted) return;
      setState(() {
        _filePath = path;
        _result = result;
        _frameCount = fc is int ? fc : (fc is num ? fc.toInt() : null);
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      appBar: AppBar(title: const Text('Animated Image (GIF / WebP)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Picks an animated image and runs scanFile. The native sampler '
              'classifies a small set of representative frames and reports '
              'the worst label.',
              style: t.typography.caption,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _pickAndScan,
              icon: const Icon(Icons.gif_box_outlined, size: 16),
              label: Text(_busy ? 'Scanning…' : 'Pick animated image'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ErrorCard(message: _error!, theme: t),
            ],
            const SizedBox(height: 16),
            if (_filePath != null)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(_filePath!),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_result != null)
                      _ResultRow(
                        result: _result!,
                        frameCount: _frameCount,
                        theme: t,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final ScanResult result;
  final int? frameCount;
  final NsfwTheme theme;
  const _ResultRow({
    required this.result,
    required this.frameCount,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: result.isNsfw
              ? theme.danger.withValues(alpha: 0.15)
              : theme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.outline),
        ),
        child: Row(children: [
          Icon(
            result.isNsfw
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline,
            color: result.isNsfw ? theme.danger : theme.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${result.topCategory.displayName} • '
                  '${(result.topConfidence * 100).toStringAsFixed(1)}%',
                  style: theme.typography.title.copyWith(fontSize: 14),
                ),
                if (frameCount != null)
                  Text('Scanned $frameCount frames',
                      style: theme.typography.caption),
              ],
            ),
          ),
        ]),
      );
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final NsfwTheme theme;
  const _ErrorCard({required this.message, required this.theme});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.danger.withValues(alpha: 0.45)),
        ),
        child: Text(message,
            style: theme.typography.caption.copyWith(color: theme.danger)),
      );
}
