import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Demonstrates scanning RAW camera files (#54). RAW formats (CR2 / NEF /
/// ARW / DNG / RAF / ORF / RW2) are decoded natively on iOS via ImageIO and
/// on Android via the camera2 RAW pipeline.
///
/// If the platform fails to decode a particular RAW variant (e.g. an
/// uncommon Olympus profile on Android), surface the documented guidance:
/// the caller should extract the embedded JPEG preview themselves and pass
/// that to [NsfwDetector.scanBytes].
class RawFormatDemoScreen extends StatefulWidget {
  const RawFormatDemoScreen({super.key});

  @override
  State<RawFormatDemoScreen> createState() => _RawFormatDemoScreenState();
}

class _RawFormatDemoScreenState extends State<RawFormatDemoScreen> {
  final TextEditingController _pathCtrl = TextEditingController();
  String? _path;
  ScanResult? _result;
  String? _error;
  bool _scanning = false;

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (!mounted || picked.isEmpty) return;
      final p = picked.first.filePath;
      if (p != null) {
        setState(() {
          _path = p;
          _pathCtrl.text = p;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _scan() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty || _scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
      _result = null;
      _path = path;
    });
    try {
      final r = await NsfwDetector.instance.scanFile(path);
      if (!mounted) return;
      setState(() {
        _result = r;
        _scanning = false;
        if (r.status == ScanStatus.failed) {
          _error = _rawGuidance(r.errorMessage ?? 'unknown decode failure');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _rawGuidance(e.toString());
        _scanning = false;
      });
    }
  }

  String _rawGuidance(String underlying) {
    final platform = Platform.isIOS
        ? 'iOS'
        : Platform.isAndroid
            ? 'Android'
            : 'this platform';
    return 'RAW format not supported on $platform — extract the embedded '
        'JPEG preview yourself and pass it to scanBytes(). '
        '(Underlying: $underlying)';
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      appBar: AppBar(title: const Text('RAW Format Demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scans a RAW file (CR2, NEF, ARW, DNG, RAF, ORF, RW2). The '
              'native decoder reads the embedded preview when available — '
              'paste a file path or pick from the library.',
              style: t.typography.caption,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  decoration: const InputDecoration(
                    labelText: 'File path',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _pick,
                icon: const Icon(Icons.folder_open_outlined),
                tooltip: 'Pick file',
              ),
            ]),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: const Icon(Icons.image_search_outlined, size: 16),
              label: Text(_scanning ? 'Scanning…' : 'Scan'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: t.danger.withValues(alpha: 0.45)),
                ),
                child: Text(_error!,
                    style:
                        t.typography.caption.copyWith(color: t.danger)),
              ),
            ],
            const SizedBox(height: 16),
            if (_result != null && _result!.status != ScanStatus.failed)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _result!.isNsfw
                      ? t.danger.withValues(alpha: 0.15)
                      : t.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.outline),
                ),
                child: Row(children: [
                  Icon(
                    _result!.isNsfw
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline,
                    color: _result!.isNsfw ? t.danger : t.success,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_result!.topCategory.displayName} • '
                      '${(_result!.topConfidence * 100).toStringAsFixed(1)}%',
                      style: t.typography.title.copyWith(fontSize: 14),
                    ),
                  ),
                ]),
              ),
            if (_path != null && File(_path!).existsSync()) ...[
              const SizedBox(height: 16),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_path!),
                    fit: BoxFit.contain,
                    // RAW formats won't render natively — show a hint.
                    errorBuilder: (_, __, ___) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Flutter cannot render this RAW directly — the '
                          'native scanner can still read the embedded preview.',
                          textAlign: TextAlign.center,
                          style: t.typography.caption,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
