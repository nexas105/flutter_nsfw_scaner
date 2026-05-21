import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:nsfw_detect/nsfw_detect.dart';

import '../main.dart';

/// Showcase for [NsfwModerationGate] (#31).
///
/// Three tabs demonstrate the three named constructors:
///   * **Bytes** — `NsfwModerationGate.bytes(...)` over asset-bundle bytes.
///   * **File** — `NsfwModerationGate.file(...)` over a file path returned
///     by `NsfwDetector.pickMedia()` (note: we use the plugin's built-in
///     picker rather than `image_picker` to avoid adding a pub dependency).
///   * **Asset** — `NsfwModerationGate.asset(...)` over a photo-library
///     local id returned by `pickMedia`.
///
/// A toggle at the top of each tab flips between the default blur fallback
/// and a custom `nsfwBuilder` (red-tinted policy card).
class ModerationGateScreen extends StatefulWidget {
  const ModerationGateScreen({super.key});

  @override
  State<ModerationGateScreen> createState() => _ModerationGateScreenState();
}

class _ModerationGateScreenState extends State<ModerationGateScreen> {
  bool _useCustomBuilder = false;

  // ──────────────────────────────────────────────────────────────────────
  // "Bytes" tab — lazy-loaded from the bundled test asset.
  // ──────────────────────────────────────────────────────────────────────
  Uint8List? _bytes;
  bool _loadingBytes = false;
  String? _bytesError;

  // ──────────────────────────────────────────────────────────────────────
  // "File" tab — populated by NsfwDetector.pickMedia (which returns a
  // filePath on platforms that surface one — iOS PHPicker / Android URI).
  // ──────────────────────────────────────────────────────────────────────
  String? _filePath;
  String? _filePathError;
  bool _pickingFile = false;

  // ──────────────────────────────────────────────────────────────────────
  // "Asset" tab — populated by NsfwDetector.pickMedia (localId only).
  // ──────────────────────────────────────────────────────────────────────
  String? _localId;
  String? _assetError;
  bool _pickingAsset = false;

  Future<void> _loadBytes() async {
    if (_loadingBytes) return;
    setState(() {
      _loadingBytes = true;
      _bytesError = null;
    });
    try {
      final data = await rootBundle.load('assets/test/safe.png');
      if (!mounted) return;
      setState(() {
        _bytes = data.buffer.asUint8List();
        _loadingBytes = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bytesError = e.toString();
        _loadingBytes = false;
      });
    }
  }

  Future<void> _pickFile() async {
    if (_pickingFile) return;
    setState(() {
      _pickingFile = true;
      _filePathError = null;
    });
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (!mounted) return;
      if (picked.isEmpty) {
        setState(() => _pickingFile = false);
        return;
      }
      final fp = picked.first.filePath;
      if (fp == null) {
        setState(() {
          _filePathError =
              'Picker did not return a file path on this platform — '
              'use the Asset tab instead.';
          _pickingFile = false;
        });
        return;
      }
      setState(() {
        _filePath = fp;
        _pickingFile = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filePathError = e.toString();
        _pickingFile = false;
      });
    }
  }

  Future<void> _pickAsset() async {
    if (_pickingAsset) return;
    setState(() {
      _pickingAsset = true;
      _assetError = null;
    });
    try {
      final picked = await NsfwDetector.instance.pickMedia(
        type: MediaPickerType.image,
        multiple: false,
      );
      if (!mounted) return;
      if (picked.isEmpty) {
        setState(() => _pickingAsset = false);
        return;
      }
      setState(() {
        _localId = picked.first.localId;
        _pickingAsset = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _assetError = e.toString();
        _pickingAsset = false;
      });
    }
  }

  /// Custom NSFW fallback — opt-in via the toggle. Demonstrates a fully
  /// app-controlled visual instead of the default blur.
  Widget _customNsfwBuilder(
    BuildContext context,
    ScanResult result,
    Widget child,
  ) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: child,
        ),
        Positioned.fill(
          child: ColoredBox(
            color: t.danger.withValues(alpha: 0.35),
            child: Center(
              child: Card(
                color: t.surface,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.block_rounded, color: t.danger, size: 32),
                      const SizedBox(height: 8),
                      Text('Content blocked',
                          style: t.typography.title.copyWith(fontSize: 16)),
                      const SizedBox(height: 4),
                      Text(
                        '${result.topCategory.displayName} • '
                        '${(result.topConfidence * 100).toStringAsFixed(0)}%',
                        style: t.typography.caption,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = resolveNsfwTheme(context, themeModeNotifier.value);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: t.gallery.scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('Moderation Gate'),
          backgroundColor: t.surface,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Bytes', icon: Icon(Icons.memory_outlined)),
              Tab(text: 'File', icon: Icon(Icons.insert_drive_file_outlined)),
              Tab(text: 'Asset', icon: Icon(Icons.photo_outlined)),
            ],
          ),
        ),
        body: Column(
          children: [
            SwitchListTile(
              title: const Text('Use custom nsfwBuilder'),
              subtitle: const Text(
                  'Toggle between the default blur and a custom red card.'),
              value: _useCustomBuilder,
              onChanged: (v) => setState(() => _useCustomBuilder = v),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _BytesTab(
                    bytes: _bytes,
                    loading: _loadingBytes,
                    error: _bytesError,
                    onLoad: _loadBytes,
                    useCustomBuilder: _useCustomBuilder,
                    customBuilder:
                        _useCustomBuilder ? _customNsfwBuilder : null,
                    theme: t,
                  ),
                  _FileTab(
                    filePath: _filePath,
                    error: _filePathError,
                    picking: _pickingFile,
                    onPick: _pickFile,
                    useCustomBuilder: _useCustomBuilder,
                    customBuilder:
                        _useCustomBuilder ? _customNsfwBuilder : null,
                    theme: t,
                  ),
                  _AssetTab(
                    localId: _localId,
                    error: _assetError,
                    picking: _pickingAsset,
                    onPick: _pickAsset,
                    useCustomBuilder: _useCustomBuilder,
                    customBuilder:
                        _useCustomBuilder ? _customNsfwBuilder : null,
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

class _BytesTab extends StatelessWidget {
  final Uint8List? bytes;
  final bool loading;
  final String? error;
  final VoidCallback onLoad;
  final bool useCustomBuilder;
  final Widget Function(BuildContext, ScanResult, Widget)? customBuilder;
  final NsfwTheme theme;

  const _BytesTab({
    required this.bytes,
    required this.loading,
    required this.error,
    required this.onLoad,
    required this.useCustomBuilder,
    required this.customBuilder,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Loads bytes from assets/test/safe.png and feeds them into '
            'NsfwModerationGate.bytes(...).',
            style: theme.typography.caption,
          ),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
              onPressed: loading ? null : onLoad,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: Text(bytes == null ? 'Load asset bytes' : 'Reload'),
            ),
            if (loading) ...[
              const SizedBox(width: 12),
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ]),
          if (error != null) ...[
            const SizedBox(height: 12),
            _ErrorText(error: error!, theme: theme),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: bytes == null
                ? _PlaceholderHint(
                    label: 'Bytes not loaded yet.',
                    theme: theme,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: NsfwModerationGate.bytes(
                      bytes!,
                      nsfwBuilder: customBuilder,
                      child: Image.memory(bytes!, fit: BoxFit.cover),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileTab extends StatelessWidget {
  final String? filePath;
  final String? error;
  final bool picking;
  final VoidCallback onPick;
  final bool useCustomBuilder;
  final Widget Function(BuildContext, ScanResult, Widget)? customBuilder;
  final NsfwTheme theme;

  const _FileTab({
    required this.filePath,
    required this.error,
    required this.picking,
    required this.onPick,
    required this.useCustomBuilder,
    required this.customBuilder,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Picks an image via NsfwDetector.pickMedia and renders it inside '
            'NsfwModerationGate.file(path). The picker returns a real file '
            'path on iOS / Android — no image_picker dep required.',
            style: theme.typography.caption,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: picking ? null : onPick,
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            label: Text(picking ? 'Picking…' : 'Pick image'),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            _ErrorText(error: error!, theme: theme),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: filePath == null
                ? _PlaceholderHint(
                    label: 'No file picked yet.',
                    theme: theme,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: NsfwModerationGate.file(
                      filePath!,
                      nsfwBuilder: customBuilder,
                      child: _FileImage(path: filePath!),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AssetTab extends StatelessWidget {
  final String? localId;
  final String? error;
  final bool picking;
  final VoidCallback onPick;
  final bool useCustomBuilder;
  final Widget Function(BuildContext, ScanResult, Widget)? customBuilder;
  final NsfwTheme theme;

  const _AssetTab({
    required this.localId,
    required this.error,
    required this.picking,
    required this.onPick,
    required this.useCustomBuilder,
    required this.customBuilder,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Picks an asset by local identifier (PHAsset on iOS, MediaStore '
            'URI on Android) and pipes it through NsfwModerationGate.asset(id).',
            style: theme.typography.caption,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: picking ? null : onPick,
            icon: const Icon(Icons.photo_library_outlined, size: 16),
            label: Text(picking ? 'Picking…' : 'Pick asset'),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            _ErrorText(error: error!, theme: theme),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: localId == null
                ? _PlaceholderHint(
                    label: 'No asset picked yet.',
                    theme: theme,
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: NsfwModerationGate.asset(
                      localId!,
                      nsfwBuilder: customBuilder,
                      // The asset id alone isn't a Flutter ImageProvider, so we
                      // show a labelled placeholder under the gate.
                      child: ColoredBox(
                        color: theme.surfaceVariant,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'Asset $localId\n(rendered by the gate when scan completes)',
                              style: theme.typography.caption,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileImage extends StatelessWidget {
  final String path;
  const _FileImage({required this.path});

  @override
  Widget build(BuildContext context) => Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Center(
          child: Icon(Icons.broken_image_outlined),
        ),
      );
}

class _PlaceholderHint extends StatelessWidget {
  final String label;
  final NsfwTheme theme;
  const _PlaceholderHint({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.surface,
            border: Border.all(color: theme.outline),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label, style: theme.typography.caption),
        ),
      );
}

class _ErrorText extends StatelessWidget {
  final String error;
  final NsfwTheme theme;
  const _ErrorText({required this.error, required this.theme});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.danger.withValues(alpha: 0.45)),
        ),
        child: Text(
          error,
          style: theme.typography.caption.copyWith(color: theme.danger),
        ),
      );
}
