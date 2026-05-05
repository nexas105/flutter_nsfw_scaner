import 'package:flutter/material.dart';
import '../api/nsfw_gallery_filter.dart';
import '../api/scan_result.dart';
import 'theme/nsfw_theme.dart';

/// Toolbar shown when [NsfwGalleryView] enters selection mode. Renders one
/// button per [NsfwBulkAction] plus a counter and a close affordance.
class NsfwSelectionToolbar extends StatelessWidget {
  final int selectedCount;
  final List<ScanResult> selectedResults;
  final List<NsfwBulkAction> actions;
  final VoidCallback onExit;
  final NsfwTheme? theme;

  const NsfwSelectionToolbar({
    super.key,
    required this.selectedCount,
    required this.selectedResults,
    required this.actions,
    required this.onExit,
    this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme ?? NsfwTheme.defaults();
    final s = t.spacing;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: s.md, vertical: s.xs),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(s.md),
        boxShadow: t.elevation.low,
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close_rounded, color: t.onSurfaceMuted),
            tooltip: 'Exit selection',
            onPressed: onExit,
          ),
          SizedBox(width: s.xs),
          Text(
            '$selectedCount selected',
            style: t.typography.body.copyWith(
              color: t.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          if (actions.isNotEmpty)
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                shrinkWrap: true,
                itemCount: actions.length,
                separatorBuilder: (_, __) => SizedBox(width: s.xs),
                itemBuilder: (_, i) {
                  final a = actions[i];
                  final tint = a.tint ?? t.accent;
                  return TextButton.icon(
                    icon: Icon(a.icon, size: 16, color: tint),
                    label: Text(
                      a.label,
                      style: t.typography.body.copyWith(
                        color: tint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(horizontal: s.sm),
                      backgroundColor: tint.withValues(alpha: 0.10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(s.sm),
                      ),
                    ),
                    onPressed: selectedCount == 0
                        ? null
                        : () => a.onInvoke(selectedResults),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
