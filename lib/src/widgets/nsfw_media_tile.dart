import 'package:flutter/material.dart';
import '../api/media_item.dart';
import '../api/scan_result.dart';
import '../l10n/nsfw_localizations.dart';
import 'nsfw_result_badge.dart';
import 'theme/nsfw_theme.dart';

typedef NsfwMediaTileBuilder = Widget Function(
  BuildContext context,
  MediaItem item,
  ScanResult? result,
  Widget thumbnail,
);

class NsfwMediaTile extends StatelessWidget {
  final MediaItem item;
  final ScanResult? result;
  final NsfwGalleryTheme theme;
  final BadgeStyle badgeStyle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool blurNsfw;
  /// When true, render a selection ring + checkmark overlay. The host (gallery)
  /// drives this state — the tile is purely presentational.
  final bool selected;
  /// Visual hint that the tile is part of a multi-select context, even when
  /// not yet selected. Renders an outline-only checkmark in the corner.
  final bool selectable;
  /// Optional override for the selection accent color. Defaults to a vivid
  /// accent close to the gallery progress-bar color.
  final Color? selectionColor;
  /// Optional thumbnail widget. When provided it replaces the default grey
  /// placeholder, allowing consumers to inject native photo thumbnails without
  /// adding a photo-library dependency to this library.
  final Widget? thumbnailWidget;

  const NsfwMediaTile({
    super.key,
    required this.item,
    this.result,
    this.theme = NsfwGalleryTheme.defaults,
    this.badgeStyle = BadgeStyle.compact,
    this.onTap,
    this.onLongPress,
    this.blurNsfw = false,
    this.selected = false,
    this.selectable = false,
    this.selectionColor,
    this.thumbnailWidget,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selectionColor ?? theme.progressBarColor;
    return Semantics(
      container: true,
      button: onTap != null,
      selected: selected,
      label: _semanticsLabel(),
      value: _semanticsValue(),
      onTap: onTap,
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: _buildTile(context, accent),
      ),
    );
  }

  String _semanticsLabel() {
    final l = NsfwLocalizations.current;
    final type = item.type == MediaType.video ? 'Video' : 'Photo';
    if (result == null) return '$type, scanning';
    final r = result!;
    switch (r.status) {
      case ScanStatus.failed:
        return '$type, scan failed';
      case ScanStatus.skipped:
        return '$type, scan skipped';
      case ScanStatus.completed:
        return '$type, ${r.topCategory.localizedName(l)}';
    }
  }

  String? _semanticsValue() {
    final r = result;
    if (r == null || r.status != ScanStatus.completed) return null;
    return '${(r.topConfidence * 100).toStringAsFixed(0)}%';
  }

  Widget _buildTile(BuildContext context, Color accent) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress ??
          () {
            final err = result?.errorMessage;
            if (err != null && err.isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(err),
                    duration: const Duration(seconds: 4)),
              );
            }
          },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: selected ? const EdgeInsets.all(3) : EdgeInsets.zero,
        decoration: BoxDecoration(
          borderRadius: theme.tileBorderRadius,
          color: selected ? accent : Colors.transparent,
        ),
        child: ClipRRect(
          borderRadius: theme.tileBorderRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _thumbnail(),
              if (item.type == MediaType.video) _videoOverlay(),
              Positioned(
                bottom: 4,
                left: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                      width: 0.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: NsfwResultBadge(
                    result: result,
                    style: badgeStyle,
                    theme: theme,
                  ),
                ),
              ),
              if (result != null && result!.isNsfw && blurNsfw)
                _blurOverlay(),
              if (selectable || selected) _selectionMark(accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectionMark(Color accent) => Positioned(
        top: 6,
        right: 6,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? accent : Colors.black.withValues(alpha: 0.45),
            border: Border.all(
              color: Colors.white,
              width: 1.5,
            ),
          ),
          child: selected
              ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
              : null,
        ),
      );

  Widget _thumbnail() {
    if (thumbnailWidget != null) return thumbnailWidget!;
    return Container(
      color: Colors.grey.shade900,
      child: const Icon(Icons.photo, color: Colors.white24),
    );
  }

  Widget _videoOverlay() => Positioned(
        top: 4,
        right: 4,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
        ),
      );

  Widget _blurOverlay() => Positioned.fill(
        child: Container(
          color: Colors.black87,
          child: const Center(
            child: Icon(Icons.visibility_off_rounded, color: Colors.white38, size: 28),
          ),
        ),
      );
}
