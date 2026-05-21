import 'package:flutter/material.dart';
import '../api/scan_result.dart';
import '../api/nsfw_label.dart';
import '../l10n/nsfw_localizations.dart';
import 'theme/nsfw_theme.dart';

enum BadgeStyle { compact, detailed, iconOnly, minimal }

class NsfwResultBadge extends StatelessWidget {
  final ScanResult? result;
  final BadgeStyle style;
  final NsfwGalleryTheme theme;
  final double? fontSize;

  const NsfwResultBadge({
    super.key,
    this.result,
    this.style = BadgeStyle.compact,
    this.theme = NsfwGalleryTheme.defaults,
    this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final Widget visual;
    if (result == null) {
      visual = _pendingBadge();
    } else if (result!.status == ScanStatus.failed) {
      visual = _errorBadge();
    } else if (result!.status == ScanStatus.skipped) {
      visual = _skippedBadge();
    } else {
      visual = _resultBadge(result!);
    }
    // Wrap the visual content in a single Semantics node so screen readers
    // announce one coherent label ("NSFW result: explicit nudity, 87%
    // confidence") instead of the raw icon + percentage fragments. The
    // visual children sit under `ExcludeSemantics` so their individual
    // `Text` / `Icon` nodes don't double-announce.
    return Semantics(
      container: true,
      label: _semanticsLabel(),
      value: _semanticsValue(),
      child: ExcludeSemantics(child: visual),
    );
  }

  String _semanticsLabel() {
    final l = NsfwLocalizations.current;
    if (result == null) return 'NSFW: ${l.confidenceVeryLow}';
    final r = result!;
    switch (r.status) {
      case ScanStatus.failed:
        return 'NSFW: error';
      case ScanStatus.skipped:
        return 'NSFW: skipped';
      case ScanStatus.completed:
        return 'NSFW: ${r.topCategory.localizedName(l)}';
    }
  }

  String? _semanticsValue() {
    final r = result;
    if (r == null || r.status != ScanStatus.completed) return null;
    final pct = (r.topConfidence * 100).toStringAsFixed(0);
    return '$pct%';
  }

  Widget _pendingBadge() => _BadgeContainer(
        color: theme.pendingColor.withValues(alpha: theme.badgeOpacity),
        child: style == BadgeStyle.iconOnly
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                ),
                if (style != BadgeStyle.minimal) ...[
                  const SizedBox(width: 4),
                  _label('Scanning'),
                ],
              ]),
      );

  Widget _errorBadge() => _BadgeContainer(
        color: Colors.orange.shade700.withValues(alpha: theme.badgeOpacity),
        child: _iconWithLabel(Icons.warning_rounded, 'Error'),
      );

  Widget _skippedBadge() => _BadgeContainer(
        color: Colors.grey.shade600.withValues(alpha: theme.badgeOpacity),
        child: _iconWithLabel(Icons.skip_next_rounded, 'Skipped'),
      );

  Widget _resultBadge(ScanResult r) {
    final color = _colorForCategory(r.topCategory).withValues(alpha: theme.badgeOpacity);
    if (style == BadgeStyle.iconOnly) {
      return _BadgeContainer(
        color: color,
        child: Icon(_iconForCategory(r.topCategory), color: Colors.white, size: 14),
      );
    }
    if (style == BadgeStyle.minimal) {
      return _BadgeContainer(color: color, child: _label(_shortLabel(r.topCategory)));
    }
    if (style == BadgeStyle.detailed) {
      return _BadgeContainer(
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _iconWithLabel(_iconForCategory(r.topCategory), r.topCategory.displayName),
            const SizedBox(height: 2),
            _label('${(r.topConfidence * 100).toStringAsFixed(0)}%', fontSize: 10),
          ],
        ),
      );
    }
    // compact
    return _BadgeContainer(
      color: color,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_iconForCategory(r.topCategory), color: Colors.white, size: 12),
        const SizedBox(width: 3),
        _label('${(r.topConfidence * 100).toStringAsFixed(0)}%'),
      ]),
    );
  }

  Widget _iconWithLabel(IconData icon, String text) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 12),
        if (style != BadgeStyle.iconOnly) ...[
          const SizedBox(width: 3),
          _label(text),
        ],
      ]);

  Widget _label(String text, {double? fontSize}) => Text(
        text,
        style: (theme.badgeLabelStyle ?? const TextStyle()).copyWith(
          color: Colors.white,
          fontSize: fontSize ?? this.fontSize ?? 11,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      );

  Color _colorForCategory(NsfwCategory cat) => switch (cat) {
        NsfwCategory.safe => theme.safeColor,
        NsfwCategory.suggestive => theme.suggestiveColor,
        NsfwCategory.nudity => theme.nsfwColor,
        NsfwCategory.explicitNudity => theme.explicitColor,
        NsfwCategory.unknown => theme.unknownColor,
      };

  IconData _iconForCategory(NsfwCategory cat) => switch (cat) {
        NsfwCategory.safe => Icons.check_circle_outline_rounded,
        NsfwCategory.suggestive => Icons.visibility_outlined,
        NsfwCategory.nudity => Icons.no_photography_outlined,
        NsfwCategory.explicitNudity => Icons.block_rounded,
        NsfwCategory.unknown => Icons.help_outline_rounded,
      };

  String _shortLabel(NsfwCategory cat) => switch (cat) {
        NsfwCategory.safe => 'SAFE',
        NsfwCategory.suggestive => 'SUGG',
        NsfwCategory.nudity => 'NSFW',
        NsfwCategory.explicitNudity => 'EXPL',
        NsfwCategory.unknown => '?',
      };
}

class _BadgeContainer extends StatelessWidget {
  final Color color;
  final Widget child;
  final EdgeInsets? padding;
  const _BadgeContainer({required this.color, required this.child, this.padding});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
        child: child,
      );
}
