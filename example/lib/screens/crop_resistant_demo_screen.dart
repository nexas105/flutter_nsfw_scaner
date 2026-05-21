import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Demonstrates the new [CropResistantCache] (#57). Pick an image, scan it,
/// then apply an 80% center crop to its bytes and look the result up in the
/// crop-resistant cache — surfacing the matching block count so the
/// developer can tune `minMatchingBlocks` for their pipeline.
class CropResistantDemoScreen extends StatefulWidget {
  const CropResistantDemoScreen({super.key});

  @override
  State<CropResistantDemoScreen> createState() =>
      _CropResistantDemoScreenState();
}

class _CropResistantDemoScreenState extends State<CropResistantDemoScreen> {
  Uint8List? _originalBytes;
  Uint8List? _croppedBytes;
  ScanResult? _scanResult;
  ScanResult? _cacheHit;
  int? _blockSimilarity;
  int? _blockTotal;
  String? _error;
  bool _busy = false;

  late final CropResistantCache _cache =
      NsfwDetector.instance.cropResistantCache;

  Future<void> _pickAndScan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _scanResult = null;
      _cacheHit = null;
      _croppedBytes = null;
      _blockSimilarity = null;
      _blockTotal = null;
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
      final bytes = await File(path).readAsBytes();
      final result = await NsfwDetector.instance.scanBytes(bytes);
      await _cache.remember(bytes, result);
      if (!mounted) return;
      setState(() {
        _originalBytes = bytes;
        _scanResult = result;
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

  Future<void> _cropAndLookup() async {
    final bytes = _originalBytes;
    if (bytes == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _cacheHit = null;
      _blockSimilarity = null;
      _blockTotal = null;
    });
    try {
      final cropped = await _centerCrop(bytes, 0.8);
      // Compute the actual block similarity for the UI so the developer can
      // see how close the crop is to the cached original.
      final hOrig = await BlockPerceptualHash.compute(bytes);
      final hCrop = await BlockPerceptualHash.compute(cropped);
      final similarity = (hOrig != null && hCrop != null)
          ? hOrig.blockSimilarity(hCrop)
          : null;
      final total = hOrig?.blocks.length;
      final hit = await _cache.lookup(cropped);
      if (!mounted) return;
      setState(() {
        _croppedBytes = cropped;
        _cacheHit = hit;
        _blockSimilarity = similarity;
        _blockTotal = total;
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

  /// Decodes [bytes], crops to the center [scale] fraction, returns PNG.
  Future<Uint8List> _centerCrop(Uint8List bytes, double scale) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final w = image.width;
    final h = image.height;
    final cw = (w * scale).round();
    final ch = (h * scale).round();
    final left = ((w - cw) / 2).round();
    final top = ((h - ch) / 2).round();

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
          left.toDouble(), top.toDouble(), cw.toDouble(), ch.toDouble()),
      Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
      ui.Paint(),
    );
    final pic = recorder.endRecording();
    final out = await pic.toImage(cw, ch);
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    pic.dispose();
    out.dispose();
    image.dispose();
    return png!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Scaffold(
      appBar: AppBar(title: const Text('Crop-Resistant Cache')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Picks an image, scans it, then crops to the center 80% and '
              'queries the crop-resistant cache. Even with significant '
              'framing changes, the block-level perceptual hash should '
              'still surface the cached result.',
              style: t.typography.caption,
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: _busy ? null : _pickAndScan,
                icon: const Icon(Icons.image_outlined, size: 16),
                label: const Text('Pick & scan'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed:
                    _originalBytes == null || _busy ? null : _cropAndLookup,
                icon: const Icon(Icons.crop_outlined, size: 16),
                label: const Text('Crop & lookup'),
              ),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_error!,
                    style:
                        t.typography.caption.copyWith(color: t.danger)),
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Pane(
                      title: 'Original',
                      bytes: _originalBytes,
                      result: _scanResult,
                      theme: t,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Pane(
                      title: 'Cropped (80%)',
                      bytes: _croppedBytes,
                      result: _cacheHit,
                      hitLabel: _cacheHit != null
                          ? 'Cache HIT'
                          : (_croppedBytes != null ? 'Cache MISS' : null),
                      similarity: _blockSimilarity,
                      similarityTotal: _blockTotal,
                      theme: t,
                    ),
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

class _Pane extends StatelessWidget {
  final String title;
  final Uint8List? bytes;
  final ScanResult? result;
  final String? hitLabel;
  final int? similarity;
  final int? similarityTotal;
  final NsfwTheme theme;
  const _Pane({
    required this.title,
    required this.bytes,
    required this.result,
    required this.theme,
    this.hitLabel,
    this.similarity,
    this.similarityTotal,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.typography.label),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: theme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: bytes == null
                ? Center(
                    child: Text('—', style: theme.typography.caption),
                  )
                : Image.memory(bytes!, fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 6),
        if (hitLabel != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: hitLabel == 'Cache HIT'
                  ? theme.success.withValues(alpha: 0.2)
                  : theme.danger.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              hitLabel!,
              style: theme.typography.mono.copyWith(
                color: hitLabel == 'Cache HIT' ? theme.success : theme.danger,
                fontSize: 11,
              ),
            ),
          ),
        if (similarity != null && similarityTotal != null) ...[
          const SizedBox(height: 4),
          Text('Matching blocks: $similarity / $similarityTotal',
              style: theme.typography.caption),
        ],
        if (result != null) ...[
          const SizedBox(height: 4),
          Text(
            '${result!.topCategory.displayName} • '
            '${(result!.topConfidence * 100).toStringAsFixed(0)}%'
            '${result!.fromCache ? "  (cache)" : ""}',
            style: theme.typography.caption,
          ),
        ],
      ],
    );
  }
}
