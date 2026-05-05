import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../main.dart';
import '../state/app_settings.dart';
import 'settings_screen.dart';
import 'detail_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  /// Hosts now own a NsfwScanController explicitly. NsfwGalleryView consumes
  /// it; the AppBar listens to the same controller via AnimatedBuilder so
  /// the live NSFW count can re-render without the screen having to mirror
  /// it back through setState.
  ///
  /// Constructed lazily in [didChangeDependencies] because `AppSettingsScope`
  /// is an InheritedWidget — `of(context)` is illegal inside [initState].
  NsfwScanController? _scanController;
  bool _controllerInitialized = false;

  int _nsfwFoundCount = 0;
  int _selectionCount = 0;
  // Demo-only: locally-tracked "hidden" set, illustrates the bulk-action API.
  final Set<String> _hiddenIds = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_controllerInitialized) {
      final settings = AppSettingsScope.of(context);
      _scanController = NsfwScanController(initialConfig: settings.config);
      _scanController!.addListener(_recomputeNsfwCount);
      _controllerInitialized = true;
    }
  }

  void _recomputeNsfwCount() {
    final c = _scanController;
    if (c == null) return;
    final next = c.results.values.where((r) => r.isNsfw).length;
    if (next != _nsfwFoundCount) {
      setState(() => _nsfwFoundCount = next);
    }
  }

  @override
  void dispose() {
    _scanController?.removeListener(_recomputeNsfwCount);
    _scanController?.dispose();
    super.dispose();
  }

  void _onResultTap(ScanResult result) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(result: result)),
    );
  }

  void _showSummarySheet(ScanSummary summary) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => NsfwScanSummarySheet(
        summary: summary,
        theme: appNsfwTheme,
        onShare: (text) =>
            Share.share(text, subject: 'NSFW Scan Report'),
      ),
    );
  }

  Future<void> _openSettings() async {
    final settings = AppSettingsScope.of(context);
    final newConfig = await Navigator.of(context).push<ScanConfiguration>(
      MaterialPageRoute(
          builder: (_) => SettingsScreen(currentConfig: settings.config)),
    );
    if (newConfig != null) {
      settings.config = newConfig;
      _scanController?.updateConfig(newConfig);
    }
  }

  void _shareBulkReport(List<ScanResult> selected) {
    if (selected.isEmpty) return;
    final nsfw = selected.where((r) => r.isNsfw).length;
    final lines = StringBuffer()
      ..writeln('NSFW Selection Report')
      ..writeln('${selected.length} selected, $nsfw NSFW')
      ..writeln('---');
    for (final r in selected.take(20)) {
      lines.writeln(
          '${r.item.localIdentifier}: ${r.topCategory.displayName} '
          '${(r.topConfidence * 100).toStringAsFixed(1)}%');
    }
    if (selected.length > 20) {
      lines.writeln('… and ${selected.length - 20} more');
    }
    Share.share(
      lines.toString().trimRight(),
      subject: 'NSFW Selection Report',
    );
  }

  /// Demo: exports the bounding-box detections of the current selection as
  /// a single JSON payload. Useful for piping into downstream moderation
  /// tooling that wants the raw NudeNet output instead of the aggregated
  /// labels. Only meaningful in detection mode.
  void _exportBoxesJson(List<ScanResult> selected) {
    final withBoxes =
        selected.where((r) => r.detections != null && r.detections!.isNotEmpty);
    if (withBoxes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No detection boxes in selection.'),
      ));
      return;
    }
    final payload = withBoxes
        .map((r) => {
              'localId': r.item.localIdentifier,
              'detections':
                  r.detections!.map((d) => d.toMap()).toList(growable: false),
            })
        .toList(growable: false);
    Share.share(
      const JsonEncoder.withIndent('  ').convert(payload),
      subject: 'Body-Part Detections',
    );
  }

  void _hideSelected(List<ScanResult> selected) {
    setState(() => _hiddenIds.addAll(selected.map((r) => r.item.localIdentifier)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Hidden ${selected.length} item(s) (demo only).'),
        backgroundColor: appNsfwTheme.surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final t = appNsfwTheme;
    final controller = _scanController;
    if (controller == null) {
      // didChangeDependencies hasn't run yet — first frame after initState.
      return const Scaffold(body: SizedBox.shrink());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionCount > 0
              ? '$_selectionCount selected'
              : 'Library Scan',
          style: t.typography.title.copyWith(fontSize: 18),
        ),
        actions: _selectionCount > 0
            ? null
            : [
                if (_nsfwFoundCount > 0)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Chip(
                      label: Text('$_nsfwFoundCount NSFW',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white)),
                      backgroundColor: t.gallery.nsfwColor,
                      padding: EdgeInsets.zero,
                      labelPadding:
                          const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _openSettings,
                  tooltip: 'Settings',
                ),
              ],
      ),
      body: NsfwGalleryView(
        controller: controller,
        theme: t.gallery,
        designTheme: t,
        crossAxisCount: 3,
        badgeStyle: BadgeStyle.compact,
        blurNsfwTiles: false,
        onResultTap: _onResultTap,
        onScanComplete: (summary) {
          setState(() => _nsfwFoundCount = summary.nsfwCount);
          _showSummarySheet(summary);
        },
        thumbnailBuilder: (context, item) => _AssetThumbnail(item: item),
        showFilterBar: true,
        showSearchField: true,
        filter: settings.filter,
        onFilterChanged: (f) => settings.filter = f,
        enableSelection: true,
        onSelectionChanged: (sel) =>
            setState(() => _selectionCount = sel.length),
        bulkActions: [
          NsfwBulkAction(
            label: 'Share',
            icon: Icons.share_rounded,
            onInvoke: _shareBulkReport,
          ),
          if (settings.config.mode == ScanMode.detection)
            NsfwBulkAction(
              label: 'Export Boxes JSON',
              icon: Icons.data_object_rounded,
              onInvoke: _exportBoxesJson,
            ),
          NsfwBulkAction(
            label: 'Hide',
            icon: Icons.visibility_off_outlined,
            tint: t.danger,
            onInvoke: _hideSelected,
          ),
        ],
      ),
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  final MediaItem item;
  const _AssetThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final typeInt = item.type == MediaType.video ? 2 : 1;
    final entity = AssetEntity(
      id: item.localIdentifier,
      typeInt: typeInt,
      width: item.width ?? 300,
      height: item.height ?? 300,
    );
    return AssetEntityImage(
      entity,
      isOriginal: false,
      thumbnailSize: const ThumbnailSize.square(300),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: appNsfwTheme.surfaceVariant,
        child: Icon(Icons.broken_image_outlined,
            color: appNsfwTheme.onSurfaceMuted),
      ),
    );
  }
}
