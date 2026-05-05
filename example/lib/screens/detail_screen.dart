import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../main.dart';

class DetailScreen extends StatelessWidget {
  final ScanResult result;

  const DetailScreen({super.key, required this.result});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF0A0A0A),
        appBar: AppBar(
          title: const Text('Result Detail'),
          backgroundColor: appNsfwTheme.surface,
          actions: [
            IconButton(
              tooltip: 'Share',
              icon: Icon(Icons.share_rounded, color: appNsfwTheme.accent),
              onPressed: () => Share.share(
                NsfwResultDetailView.defaultReportText(result),
                subject: 'NSFW Result',
              ),
            ),
          ],
        ),
        body: NsfwResultDetailView(
          result: result,
          theme: appNsfwTheme,
          thumbnailBuilder: (_, item) => _FullThumbnail(item: item),
          showDistributionChart: true,
          onShare: (text) =>
              Share.share(text, subject: 'NSFW Result'),
        ),
      );
}

class _FullThumbnail extends StatelessWidget {
  final MediaItem item;

  const _FullThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final typeInt = item.type == MediaType.video ? 2 : 1;
    final entity = AssetEntity(
      id: item.localIdentifier,
      typeInt: typeInt,
      width: item.width ?? 800,
      height: item.height ?? 800,
    );
    return AssetEntityImage(
      entity,
      isOriginal: true,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: appNsfwTheme.surfaceVariant,
        child: Icon(Icons.photo,
            size: 80, color: appNsfwTheme.onSurfaceMuted),
      ),
    );
  }
}
