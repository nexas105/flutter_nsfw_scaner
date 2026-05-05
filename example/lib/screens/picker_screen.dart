import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../main.dart';

/// Showcase for the one-shot picker APIs:
///   * Pick & Scan — `NsfwDetector.pickAndScan(...)` returns a [ScanSession]
///     that streams classifications.
///   * Pick Only — `NsfwDetector.pickMedia(...)` returns raw [PickedMedia]
///     items, scanning is deferred until the user taps a card.
class PickerScreen extends StatefulWidget {
  const PickerScreen({super.key});

  @override
  State<PickerScreen> createState() => _PickerScreenState();
}

class _PickerScreenState extends State<PickerScreen> {
  ScanSession? _session;
  StreamSubscription<ScanResult>? _resultSub;
  final List<ScanResult> _scanned = [];

  final List<PickedMedia> _picked = [];
  final Map<String, ScanResult> _onDemand = {};
  final Set<String> _scanning = {};

  @override
  void dispose() {
    _resultSub?.cancel();
    _session?.cancel();
    super.dispose();
  }

  void _onSession(ScanSession session) {
    _resultSub?.cancel();
    setState(() {
      _scanned.clear();
      _session = session;
    });
    _resultSub = session.results.listen((r) {
      if (!mounted) return;
      setState(() => _scanned.add(r));
    });
  }

  void _onPicked(List<PickedMedia> media) {
    setState(() {
      _picked
        ..clear()
        ..addAll(media);
      _onDemand.clear();
      _scanning.clear();
    });
  }

  Future<void> _classifyOnDemand(PickedMedia media) async {
    if (_scanning.contains(media.localId)) return;
    setState(() => _scanning.add(media.localId));
    try {
      final result =
          await NsfwDetector.instance.scanAsset(media.localId);
      if (mounted) {
        setState(() {
          _onDemand[media.localId] = result;
          _scanning.remove(media.localId);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _scanning.remove(media.localId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scan failed: $e'),
            backgroundColor: appNsfwTheme.danger,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = appNsfwTheme;
    return Scaffold(
      backgroundColor: t.gallery.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Picker Demo',
            style: t.typography.title.copyWith(fontSize: 18)),
        backgroundColor: t.surface,
      ),
      body: ListView(
        padding: EdgeInsets.all(t.spacing.lg),
        children: [
          _SectionHeader(label: 'Pick & Scan', theme: t),
          Text(
            'Open the native picker, then stream NSFW classifications for each '
            'selected item via the returned ScanSession.',
            style: t.typography.caption,
          ),
          SizedBox(height: t.spacing.md),
          Row(children: [
            Expanded(
              child: NsfwPickerButton(
                label: 'Pick & Scan',
                onSession: _onSession,
                maxItems: 5,
                theme: t,
              ),
            ),
          ]),
          SizedBox(height: t.spacing.lg),
          if (_scanned.isEmpty)
            _emptyHint(t, 'Picked + scanned items will appear here.')
          else
            ..._scanned.map((r) => _ScanResultCard(result: r, theme: t)),
          SizedBox(height: t.spacing.xl),
          _SectionHeader(label: 'Pick Only', theme: t),
          Text(
            'Open the picker without scanning. Tap "Classify" on a card to run '
            'NsfwDetector.scanAsset(localId) on demand.',
            style: t.typography.caption,
          ),
          SizedBox(height: t.spacing.md),
          Row(children: [
            Expanded(
              child: NsfwPickMediaButton(
                label: 'Pick Only',
                onPicked: _onPicked,
                multiple: true,
                maxItems: 8,
                theme: t,
              ),
            ),
          ]),
          SizedBox(height: t.spacing.lg),
          if (_picked.isEmpty)
            _emptyHint(t, 'Picked items will appear here.')
          else
            ..._picked.map(
              (p) => _PickedMediaCard(
                media: p,
                result: _onDemand[p.localId],
                isScanning: _scanning.contains(p.localId),
                onClassify: () => _classifyOnDemand(p),
                theme: t,
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHint(NsfwTheme t, String text) => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
            horizontal: t.spacing.lg, vertical: t.spacing.lg),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(t.spacing.md),
          border: Border.all(color: t.outline),
        ),
        child: Text(text,
            style: t.typography.caption, textAlign: TextAlign.center),
      );
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final NsfwTheme theme;
  const _SectionHeader({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: theme.spacing.sm),
        child: Text(label.toUpperCase(), style: theme.typography.label),
      );
}

class _ScanResultCard extends StatelessWidget {
  final ScanResult result;
  final NsfwTheme theme;
  const _ScanResultCard({required this.result, required this.theme});

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return Container(
      margin: EdgeInsets.only(bottom: t.spacing.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(t.spacing.md),
        boxShadow: t.elevation.low,
      ),
      child: Padding(
        padding: EdgeInsets.all(t.spacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(t.spacing.sm),
              child: SizedBox(
                width: 84,
                height: 84,
                child: _MediaItemThumbnail(item: result.item),
              ),
            ),
            SizedBox(width: t.spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NsfwResultBadge(
                    result: result,
                    style: BadgeStyle.detailed,
                    theme: t.gallery,
                    fontSize: 13,
                  ),
                  SizedBox(height: t.spacing.sm),
                  ...result.labels
                      .take(3)
                      .map((l) => NsfwLabelBar(label: l, theme: t)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickedMediaCard extends StatelessWidget {
  final PickedMedia media;
  final ScanResult? result;
  final bool isScanning;
  final VoidCallback onClassify;
  final NsfwTheme theme;

  const _PickedMediaCard({
    required this.media,
    required this.result,
    required this.isScanning,
    required this.onClassify,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final asMediaItem = MediaItem(
      localIdentifier: media.localId,
      type: media.mediaType == 'video' ? MediaType.video : MediaType.image,
      width: media.width,
      height: media.height,
      duration: media.durationMs != null
          ? Duration(milliseconds: media.durationMs!)
          : null,
    );

    return Container(
      margin: EdgeInsets.only(bottom: t.spacing.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(t.spacing.md),
        boxShadow: t.elevation.low,
      ),
      child: Padding(
        padding: EdgeInsets.all(t.spacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(t.spacing.sm),
              child: SizedBox(
                width: 84,
                height: 84,
                child: _MediaItemThumbnail(item: asMediaItem),
              ),
            ),
            SizedBox(width: t.spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media.mediaType.toUpperCase(),
                    style: t.typography.label,
                  ),
                  SizedBox(height: t.spacing.xs),
                  Text(
                    media.localId,
                    style: t.typography.mono,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: t.spacing.sm),
                  if (result != null)
                    NsfwResultBadge(
                      result: result,
                      style: BadgeStyle.detailed,
                      theme: t.gallery,
                      fontSize: 12,
                    )
                  else
                    FilledButton.icon(
                      onPressed: isScanning ? null : onClassify,
                      icon: isScanning
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search_rounded, size: 16),
                      label: Text(isScanning ? 'Scanning…' : 'Classify'),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        padding: EdgeInsets.symmetric(
                          horizontal: t.spacing.md,
                          vertical: t.spacing.sm,
                        ),
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

class _MediaItemThumbnail extends StatelessWidget {
  final MediaItem item;
  const _MediaItemThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final typeInt = item.type == MediaType.video ? 2 : 1;
    final entity = AssetEntity(
      id: item.localIdentifier,
      typeInt: typeInt,
      width: item.width ?? 200,
      height: item.height ?? 200,
    );
    return AssetEntityImage(
      entity,
      isOriginal: false,
      thumbnailSize: const ThumbnailSize.square(200),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: appNsfwTheme.surfaceVariant,
        child: Icon(Icons.broken_image_outlined,
            color: appNsfwTheme.onSurfaceMuted),
      ),
    );
  }
}
