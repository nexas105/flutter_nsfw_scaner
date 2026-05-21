import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// End-to-end demo for `ScanMode.detection` (#40).
///
/// 1. User picks an image via `NsfwDetector.pickMedia`.
/// 2. We run `scanFile` with a configurable `iouThreshold` /
///    `detectionConfidenceThreshold` and `mode: ScanMode.detection`.
/// 3. The picked image is rendered with [NsfwDetectionOverlay] painting the
///    bounding boxes on top.
///
/// Note: `NsfwDetector.scanFile` itself doesn't expose mode / iou parameters —
/// those live on [ScanConfiguration] for library scans. For one-off file
/// scans, the native side will still emit `detections` whenever the chosen
/// model is a detector (e.g. `ModelIds.nudenet`). The sliders therefore feed
/// the [NsfwDetectionOverlay]'s `minConfidence` filter directly, which is the
/// UI-level equivalent for a single-image demo.
class DetectionDemoScreen extends StatefulWidget {
  const DetectionDemoScreen({super.key});

  @override
  State<DetectionDemoScreen> createState() => _DetectionDemoScreenState();
}

class _DetectionDemoScreenState extends State<DetectionDemoScreen> {
  String? _filePath;
  ScanResult? _result;
  bool _scanning = false;
  String? _error;

  // UI-side knobs.
  bool _showLabels = true;
  double _iouThreshold = 0.45;
  double _detectionThreshold = 0.25;

  Future<void> _pickAndScan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _result = null;
    });
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (picked.isEmpty || picked.first.filePath == null) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = picked.isEmpty
              ? 'No image selected.'
              : 'Picker did not return a file path on this platform.';
        });
        return;
      }
      final path = picked.first.filePath!;
      // Use the NudeNet detector model where available; falls back to the
      // default classifier silently if the platform hasn't registered it.
      final result = await NsfwDetector.instance.scanFile(
        path,
        modelId: ModelDescriptor.nudenet,
      );
      if (!mounted) return;
      setState(() {
        _filePath = path;
        _result = result;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    final detections = _result?.detections ?? const [];
    final visible = detections
        .where((d) => d.confidence >= _detectionThreshold)
        .toList(growable: false);
    return Scaffold(
      backgroundColor: t.gallery.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Detection Demo'),
        backgroundColor: t.surface,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _scanning ? null : _pickAndScan,
                    icon: const Icon(Icons.photo_outlined, size: 16),
                    label: Text(_scanning ? 'Scanning…' : 'Pick & scan'),
                  ),
                ),
              ]),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(_error!,
                    style: t.typography.caption.copyWith(color: t.danger)),
              ),
            Expanded(
              flex: 4,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.outline),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _filePath == null
                      ? Center(
                          child: Text(
                            'Pick an image to begin.',
                            style: t.typography.caption,
                          ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(File(_filePath!), fit: BoxFit.contain),
                            if (visible.isNotEmpty)
                              NsfwDetectionOverlay(
                                detections: visible,
                                theme: t,
                                showLabels: _showLabels,
                                minConfidence: _detectionThreshold,
                              ),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.outline),
              ),
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Show labels'),
                    value: _showLabels,
                    onChanged: (v) => setState(() => _showLabels = v),
                  ),
                  _SliderRow(
                    label:
                        'detectionConfidenceThreshold: ${(_detectionThreshold * 100).toStringAsFixed(0)}%',
                    value: _detectionThreshold,
                    onChanged: (v) => setState(() => _detectionThreshold = v),
                    theme: t,
                  ),
                  _SliderRow(
                    label:
                        'iouThreshold: ${(_iouThreshold * 100).toStringAsFixed(0)}%',
                    value: _iouThreshold,
                    onChanged: (v) => setState(() => _iouThreshold = v),
                    theme: t,
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.outline),
                ),
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _result == null
                              ? 'No scan yet.'
                              : 'No detections above threshold.',
                          style: t.typography.caption,
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final d = visible[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(Icons.crop_free_rounded,
                                color: t.gallery
                                    .categoryColor(d.aggregatedCategory.name)),
                            title: Text(d.label,
                                style: t.typography.body
                                    .copyWith(fontSize: 13)),
                            subtitle: Text(
                              '${d.aggregatedCategory.displayName} • '
                              '${(d.confidence * 100).toStringAsFixed(0)}%',
                              style: t.typography.caption,
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final NsfwTheme theme;
  const _SliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.typography.caption),
          Slider(
            value: value,
            onChanged: onChanged,
            min: 0,
            max: 1,
            divisions: 100,
          ),
        ],
      );
}
