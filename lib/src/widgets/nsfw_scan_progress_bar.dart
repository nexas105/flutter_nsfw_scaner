import 'package:flutter/material.dart';
import '../api/scan_progress.dart';
import 'theme/nsfw_theme.dart';

enum ProgressBarStyle { linear, compact, textOnly }

/// Default formatter used when [NsfwScanProgressBar.etaFormatter] is null.
/// Conservative: hides the ETA for the first ~3s (`Duration < 2s` reads as
/// "0s remaining" otherwise), rounds to seconds under a minute, minutes
/// thereafter.
String defaultEtaLabel(Duration remaining) {
  if (remaining < const Duration(seconds: 2)) return 'finishing up';
  if (remaining < const Duration(minutes: 1)) {
    return '~${remaining.inSeconds}s remaining';
  }
  final mins = remaining.inMinutes;
  final secs = remaining.inSeconds - mins * 60;
  if (mins < 10 && secs > 0) return '~${mins}m ${secs}s remaining';
  return '~${mins}m remaining';
}

class NsfwScanProgressBar extends StatelessWidget {
  final Stream<ScanProgress> progressStream;
  final ProgressBarStyle style;
  final bool showItemCount;

  /// When true, the linear / text-only variants append a humanised
  /// `ScanProgress.estimatedRemaining` to the count label. No-op when the
  /// stream has not yet observed enough progress events to compute a rate
  /// (i.e. `progress.estimatedRemaining == null`).
  final bool showEta;

  /// Optional override of the ETA label. Defaults to [defaultEtaLabel].
  final String Function(Duration remaining)? etaFormatter;

  final NsfwGalleryTheme theme;

  const NsfwScanProgressBar({
    super.key,
    required this.progressStream,
    this.style = ProgressBarStyle.linear,
    this.showItemCount = true,
    this.showEta = false,
    this.etaFormatter,
    this.theme = NsfwGalleryTheme.defaults,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<ScanProgress>(
        stream: progressStream,
        builder: (context, snapshot) {
          final progress = snapshot.data;
          if (progress == null) return const SizedBox.shrink();

          return switch (style) {
            ProgressBarStyle.linear => _LinearBar(
                progress: progress,
                theme: theme,
                showCount: showItemCount,
                showEta: showEta,
                etaFormatter: etaFormatter ?? defaultEtaLabel,
              ),
            ProgressBarStyle.compact =>
              _CompactBar(progress: progress, theme: theme),
            ProgressBarStyle.textOnly => _TextOnly(
                progress: progress,
                theme: theme,
                showEta: showEta,
                etaFormatter: etaFormatter ?? defaultEtaLabel,
              ),
          };
        },
      );
}

class _LinearBar extends StatelessWidget {
  final ScanProgress progress;
  final NsfwGalleryTheme theme;
  final bool showCount;
  final bool showEta;
  final String Function(Duration) etaFormatter;
  const _LinearBar({
    required this.progress,
    required this.theme,
    required this.showCount,
    required this.showEta,
    required this.etaFormatter,
  });

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
              _buildLabel(),
              style: theme.progressTextStyle ??
                  TextStyle(fontSize: 12, color: Colors.grey.shade400),
              textAlign: TextAlign.end,
            ),
          ],
        ],
      );

  String _buildLabel() {
    if (progress.isComplete) {
      return 'Scan complete — ${progress.totalCount} items';
    }
    final base = '${progress.scannedCount} / ${progress.totalCount} scanned';
    if (!showEta) return base;
    final eta = progress.estimatedRemaining;
    if (eta == null) return base;
    return '$base · ${etaFormatter(eta)}';
  }
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
  final bool showEta;
  final String Function(Duration) etaFormatter;
  const _TextOnly({
    required this.progress,
    required this.theme,
    required this.showEta,
    required this.etaFormatter,
  });

  @override
  Widget build(BuildContext context) {
    String label;
    if (progress.isComplete) {
      label = 'Done — ${progress.totalCount} items scanned';
    } else {
      label = '${progress.scannedCount} of ${progress.totalCount}';
      final eta = progress.estimatedRemaining;
      if (showEta && eta != null) {
        label = '$label · ${etaFormatter(eta)}';
      }
    }
    return Text(
      label,
      style: theme.progressTextStyle ??
          TextStyle(fontSize: 12, color: Colors.grey.shade400),
    );
  }
}
