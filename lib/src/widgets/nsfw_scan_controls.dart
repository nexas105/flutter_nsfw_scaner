import 'package:flutter/material.dart';
import 'theme/nsfw_theme.dart';

class NsfwScanControls extends StatelessWidget {
  final bool isScanning;
  final VoidCallback onStart;
  final VoidCallback? onStop;
  final VoidCallback? onSettings;
  final NsfwGalleryTheme theme;

  const NsfwScanControls({
    super.key,
    required this.isScanning,
    required this.onStart,
    this.onStop,
    this.onSettings,
    this.theme = NsfwGalleryTheme.defaults,
  });

  @override
  Widget build(BuildContext context) => Row(
        children: [
          if (onSettings != null)
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: onSettings,
              tooltip: 'Scan settings',
              color: Colors.grey.shade300,
            ),
          const Spacer(),
          if (isScanning)
            FilledButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: const Text('Stop'),
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            )
          else
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.search_rounded, size: 18),
              label: const Text('Scan Library'),
              style: FilledButton.styleFrom(backgroundColor: theme.progressBarColor),
            ),
        ],
      );
}
