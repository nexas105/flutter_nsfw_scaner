// Focused web demo entrypoint for the nsfw_detect web platform (2.6.0).
//
// The main example app uses `dart:io` in several screens and cannot compile
// for web. This standalone entrypoint exercises only the web-supported
// one-shot APIs — pick a file, classify it with nsfwjs, optionally run NudeNet
// detection.
//
//   flutter run -d chrome -t lib/web_demo.dart
//
// (run from the `example/` directory.)

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_web.dart' show NsfwWebConfig;

void main() => runApp(const WebDemoApp());

class WebDemoApp extends StatelessWidget {
  const WebDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'nsfw_detect — Web Demo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const WebDemoScreen(),
      );
}

class WebDemoScreen extends StatefulWidget {
  const WebDemoScreen({super.key});

  @override
  State<WebDemoScreen> createState() => _WebDemoScreenState();
}

class _WebDemoScreenState extends State<WebDemoScreen> {
  final _modelUrlController = TextEditingController();

  String? _imageUrl;
  ScanResult? _result;
  String? _error;
  bool _busy = false;
  String _mode = '';

  @override
  void dispose() {
    _modelUrlController.dispose();
    super.dispose();
  }

  Future<void> _scan({required bool detect}) async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _imageUrl = null;
      _mode = detect ? 'NudeNet detection' : 'nsfwjs classification';
    });
    try {
      if (detect) {
        final url = _modelUrlController.text.trim();
        if (url.isEmpty) {
          throw StateError(
            'Set a NudeNet .onnx model URL above before running detection.',
          );
        }
        NsfwWebConfig.nudeNetModelUrl = url;
      }

      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
      );
      if (picked.isEmpty || picked.first.filePath == null) {
        setState(() => _busy = false);
        return;
      }

      final media = picked.first;
      final result = await NsfwDetector.instance.scanFile(
        media.filePath!,
        modelId: detect ? ModelDescriptor.nudenet : null,
      );

      setState(() {
        _imageUrl = media.filePath;
        _result = result;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('nsfw_detect — Web Demo'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Classification runs on nsfwjs (TensorFlow.js). Detection '
                'runs NudeNet via onnxruntime-web — it needs a model URL.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _modelUrlController,
                decoration: const InputDecoration(
                  labelText: 'NudeNet .onnx URL (detection only)',
                  hintText: 'https://your-host.example/nudenet_320n.onnx',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _scan(detect: false),
                    icon: const Icon(Icons.image_search),
                    label: const Text('Pick & classify'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : () => _scan(detect: true),
                    icon: const Icon(Icons.crop_free),
                    label: const Text('Pick & detect'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text('Running $_mode…'),
                    ],
                  ),
                ),
              if (_error != null) _ErrorCard(message: _error!),
              if (_imageUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    _imageUrl!,
                    height: 220,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (_result != null) _ResultCard(result: _result!),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final detections = result.detections ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.isNsfw ? Icons.warning_amber : Icons.check_circle,
                  color: result.isNsfw ? Colors.red : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(
                  result.isNsfw ? 'Flagged NSFW' : 'Looks safe',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(height: 24),
            Text('Status: ${result.status.name}'),
            Text(
              'Top: ${result.topCategory.name} '
              '(${(result.topConfidence * 100).toStringAsFixed(1)}%)',
            ),
            const SizedBox(height: 8),
            const Text('Labels:'),
            for (final label in result.labels)
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  '• ${label.category.name}: '
                  '${(label.confidence * 100).toStringAsFixed(1)}%',
                ),
              ),
            if (detections.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Detections (${detections.length}):'),
              for (final d in detections)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 2),
                  child: Text(
                    '• ${d.label} '
                    '${(d.confidence * 100).toStringAsFixed(1)}% '
                    '→ ${d.aggregatedCategory.name}',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
