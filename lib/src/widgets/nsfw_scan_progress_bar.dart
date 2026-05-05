import 'package:flutter/material.dart';
import '../api/scan_progress.dart';
import 'theme/nsfw_theme.dart';

enum ProgressBarStyle { linear, compact, textOnly }

class NsfwScanProgressBar extends StatelessWidget {
  final Stream<ScanProgress> progressStream;
  final ProgressBarStyle style;
  final bool showItemCount;
  final NsfwGalleryTheme theme;

  const NsfwScanProgressBar({
    super.key,
    required this.progressStream,
    this.style = ProgressBarStyle.linear,
    this.showItemCount = true,
    this.theme = NsfwGalleryTheme.defaults,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<ScanProgress>(
        stream: progressStream,
        builder: (context, snapshot) {
          final progress = snapshot.data;
          if (progress == null) return const SizedBox.shrink();

          return switch (style) {
            ProgressBarStyle.linear =>
              _LinearBar(progress: progress, theme: theme, showCount: showItemCount),
            ProgressBarStyle.compact =>
              _CompactBar(progress: progress, theme: theme),
            ProgressBarStyle.textOnly =>
              _TextOnly(progress: progress, theme: theme),
          };
        },
      );
}

class _LinearBar extends StatelessWidget {
  final ScanProgress progress;
  final NsfwGalleryTheme theme;
  final bool showCount;
  const _LinearBar({required this.progress, required this.theme, required this.showCount});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.isComplete ? 1.0 : progress.fraction,
              backgroundColor: theme.progressBarColor.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation(theme.progressBarColor),
              minHeight: 4,
            ),
          ),
          if (showCount) ...[
            const SizedBox(height: 4),
            Text(
              progress.isComplete
                  ? 'Scan complete — ${progress.totalCount} items'
                  : '${progress.scannedCount} / ${progress.totalCount} scanned',
              style: theme.progressTextStyle ??
                  TextStyle(fontSize: 12, color: Colors.grey.shade400),
              textAlign: TextAlign.end,
            ),
          ],
        ],
      );
}

class _CompactBar extends StatelessWidget {
  final ScanProgress progress;
  final NsfwGalleryTheme theme;
  const _CompactBar({required this.progress, required this.theme});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress.isComplete ? 1.0 : progress.fraction,
                backgroundColor: theme.progressBarColor.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation(theme.progressBarColor),
                minHeight: 3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(progress.fraction * 100).toStringAsFixed(0)}%',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
          ),
        ],
      );
}

class _TextOnly extends StatelessWidget {
  final ScanProgress progress;
  final NsfwGalleryTheme theme;
  const _TextOnly({required this.progress, required this.theme});

  @override
  Widget build(BuildContext context) => Text(
        progress.isComplete
            ? 'Done — ${progress.totalCount} items scanned'
            : '${progress.scannedCount} of ${progress.totalCount}',
        style: theme.progressTextStyle ?? TextStyle(fontSize: 12, color: Colors.grey.shade400),
      );
}
