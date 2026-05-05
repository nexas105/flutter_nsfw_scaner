import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api/media_item.dart';
import '../api/nsfw_label.dart';
import '../api/scan_result.dart';
import 'nsfw_result_badge.dart';
import 'theme/nsfw_theme.dart';

/// Animated horizontal bar showing the confidence of one [NsfwLabel].
/// Suitable as a building block for custom detail layouts.
class NsfwLabelBar extends StatelessWidget {
  final NsfwLabel label;
  final NsfwTheme? theme;

  const NsfwLabelBar({super.key, required this.label, this.theme});

  @override
  Widget build(BuildContext context) {
    final t = theme ?? NsfwTheme.defaults();
    final color = t.gallery.categoryColor(label.category.name);
    final s = t.spacing;
    return Padding(
      padding: EdgeInsets.only(bottom: s.sm + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label.category.displayName,
                  style: t.typography.body.copyWith(color: t.onSurfaceMuted),
                ),
              ),
              Text(
                '${(label.confidence * 100).toStringAsFixed(1)}%',
                style: t.typography.body.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: s.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: label.confidence.clamp(0.0, 1.0)),
              duration: t.animations.slow,
              curve: t.animations.curve,
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                backgroundColor: color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Detailed read-only view of a single [ScanResult]. Renders a square
/// thumbnail, a detailed badge, the per-label confidence bars, and a metadata
/// card. Photo-library agnostic — supply [thumbnailBuilder] to inject your own
/// image widget (e.g. via `photo_manager`).
class NsfwResultDetailView extends StatelessWidget {
  final ScanResult result;
  final NsfwTheme? theme;
  final Widget Function(BuildContext context, MediaItem item)? thumbnailBuilder;
  final EdgeInsets padding;

  /// Optional share callback. When non-null an outlined "Share" action is
  /// rendered under the meta card. The callback receives a pre-formatted
  /// classification report — see [defaultReportText].
  final void Function(String text)? onShare;

  /// Optional extra action widgets rendered below the meta card (between the
  /// meta card and the optional share button). Mirrors the API on
  /// [NsfwScanSummarySheet].
  final List<Widget>? extraActions;

  /// When true, render a small donut chart visualising the top-3 labels
  /// above the meta card. Pure CustomPainter — no extra dependencies.
  final bool showDistributionChart;

  const NsfwResultDetailView({
    super.key,
    required this.result,
    this.theme,
    this.thumbnailBuilder,
    this.padding = const EdgeInsets.all(16),
    this.onShare,
    this.extraActions,
    this.showDistributionChart = false,
  });

  /// Default classification report text. Public so consumers can extend it
  /// before piping through their share channel.
  static String defaultReportText(ScanResult r) {
    final lines = StringBuffer()
      ..writeln('Scan Result: ${r.topCategory.displayName} '
          '${(r.topConfidence * 100).toStringAsFixed(1)}%')
      ..writeln('Labels:');
    for (final l in r.labels) {
      lines.writeln(
          '  - ${l.category.displayName}: ${(l.confidence * 100).toStringAsFixed(1)}%');
    }
    return lines.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final t = theme ?? NsfwTheme.defaults();
    final s = t.spacing;
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(s.md),
            child: AspectRatio(
              aspectRatio: 1,
              child: thumbnailBuilder?.call(context, result.item) ??
                  _placeholder(t),
            ),
          ),
          SizedBox(height: s.lg),
          Center(
            child: NsfwResultBadge(
              result: result,
              style: BadgeStyle.detailed,
              theme: t.gallery,
              fontSize: 14,
            ),
          ),
          SizedBox(height: s.xl),
          Text('Classification Breakdown', style: t.typography.title),
          SizedBox(height: s.md),
          if (showDistributionChart && result.labels.isNotEmpty) ...[
            Center(
              child: SizedBox(
                width: 140,
                height: 140,
                child: _DistributionDonut(result: result, theme: t),
              ),
            ),
            SizedBox(height: s.md),
          ],
          ...result.labels.map((l) => NsfwLabelBar(label: l, theme: t)),
          SizedBox(height: s.lg),
          _MetaCard(result: result, theme: t),
          if (extraActions != null && extraActions!.isNotEmpty) ...[
            SizedBox(height: s.md),
            ...extraActions!,
          ],
          if (onShare != null) ...[
            SizedBox(height: s.md),
            OutlinedButton.icon(
              onPressed: () => onShare!.call(defaultReportText(result)),
              icon: Icon(Icons.share_rounded, color: t.accent),
              label: Text(
                'Share Report',
                style: TextStyle(color: t.accent, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: t.accent),
                padding: EdgeInsets.symmetric(vertical: s.md - 2),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _placeholder(NsfwTheme t) => Container(
        color: t.surfaceVariant,
        child: Icon(Icons.photo_outlined, size: 80, color: t.onSurfaceMuted),
      );
}

class _DistributionDonut extends StatelessWidget {
  final ScanResult result;
  final NsfwTheme theme;
  const _DistributionDonut({required this.result, required this.theme});

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final top3 = result.labels.take(3).toList();
    final colors = top3
        .map((l) => t.gallery.categoryColor(l.category.name))
        .toList(growable: false);
    final values = top3.map((l) => l.confidence).toList(growable: false);
    return CustomPaint(
      painter: _DonutPainter(
        values: values,
        colors: colors,
        backgroundColor: t.surfaceVariant,
      ),
      child: Center(
        child: Text(
          '${(result.topConfidence * 100).round()}%',
          style: t.typography.title.copyWith(fontSize: 18),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final Color backgroundColor;
  _DonutPainter({
    required this.values,
    required this.colors,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inset = size.shortestSide * 0.10;
    final ringRect = rect.deflate(inset);
    const strokeWidth = 14.0;

    // Background ring
    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(ringRect, 0, 6.283, false, bgPaint);

    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;

    var start = -1.5708; // -90deg
    for (var i = 0; i < values.length; i++) {
      final sweep = (values[i] / total) * 6.283;
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(ringRect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.values != values || old.colors != colors;
}

class _MetaCard extends StatelessWidget {
  final ScanResult result;
  final NsfwTheme theme;
  const _MetaCard({required this.result, required this.theme});

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final s = t.spacing;
    final item = result.item;
    return Container(
      padding: EdgeInsets.all(s.md + 2),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(s.md),
        boxShadow: t.elevation.low,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Metadata',
              style: t.typography.body.copyWith(
                fontWeight: FontWeight.w700,
                color: t.onSurface,
              )),
          SizedBox(height: s.sm + 2),
          _Row(label: 'Type', value: item.type.name.toUpperCase(), theme: t),
          _Row(
            label: 'Local ID',
            value: item.localIdentifier,
            mono: true,
            copyOnLongPress: true,
            theme: t,
          ),
          _Row(label: 'Top label', value: result.topCategory.displayName, theme: t),
          _Row(
            label: 'Top confidence',
            value: '${(result.topConfidence * 100).toStringAsFixed(1)}%',
            theme: t,
          ),
          if (item.creationDate != null)
            _Row(label: 'Date', value: _formatDate(item.creationDate!), theme: t),
          if (item.duration != null)
            _Row(label: 'Duration', value: '${item.duration!.inSeconds}s', theme: t),
          if (item.width != null && item.height != null)
            _Row(
              label: 'Resolution',
              value: '${item.width}x${item.height}',
              theme: t,
            ),
          _Row(label: 'Scanned at', value: _formatDate(result.scannedAt), theme: t),
          if (result.fromCache)
            _Row(label: 'Source', value: 'Cache', theme: t),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) => '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final bool copyOnLongPress;
  final NsfwTheme theme;

  const _Row({
    required this.label,
    required this.value,
    required this.theme,
    this.mono = false,
    this.copyOnLongPress = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final valueText = Text(
      value,
      style: (mono ? t.typography.mono : t.typography.body).copyWith(
        color: t.onSurface.withValues(alpha: 0.85),
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );

    final wrapped = copyOnLongPress
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: valueText,
          )
        : valueText;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.spacing.xs - 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: t.typography.caption),
          ),
          Expanded(child: wrapped),
        ],
      ),
    );
  }
}
