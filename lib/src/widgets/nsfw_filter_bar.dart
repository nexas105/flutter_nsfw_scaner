import 'package:flutter/material.dart';
import '../api/media_item.dart';
import '../api/nsfw_gallery_filter.dart';
import '../api/nsfw_label.dart';
import 'theme/nsfw_theme.dart';

/// Horizontal pill row letting users edit a [NsfwGalleryFilter]. Each pill
/// opens a small picker (modal bottom sheet) to mutate one facet. The bar is
/// presentation-only — it never touches scan data; pass the new value back via
/// [onChanged].
class NsfwFilterBar extends StatelessWidget {
  final NsfwGalleryFilter value;
  final ValueChanged<NsfwGalleryFilter> onChanged;
  final NsfwTheme? theme;
  final EdgeInsets padding;

  const NsfwFilterBar({
    super.key,
    required this.value,
    required this.onChanged,
    this.theme,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final t = theme ?? NsfwTheme.defaults();
    return Padding(
      padding: padding,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _Pill(
              theme: t,
              label: _confidenceLabel(),
              active: value.minConfidence > 0.0 || value.maxConfidence < 1.0,
              onTap: () => _openConfidenceSheet(context, t),
            ),
            SizedBox(width: t.spacing.xs),
            _Pill(
              theme: t,
              label: _categoryLabel(),
              active: value.categories.length < 5,
              onTap: () => _openCategorySheet(context, t),
            ),
            SizedBox(width: t.spacing.xs),
            _Pill(
              theme: t,
              label: _mediaTypeLabel(),
              active: value.mediaTypes.length < 4,
              onTap: () => _openMediaTypeSheet(context, t),
            ),
            SizedBox(width: t.spacing.xs),
            _Pill(
              theme: t,
              label: _dateLabel(),
              active: value.dateRange != null,
              onTap: () => _openDateSheet(context, t),
            ),
            SizedBox(width: t.spacing.xs),
            _Pill(
              theme: t,
              label: 'NSFW only',
              active: value.onlyNsfw,
              onTap: () =>
                  onChanged(value.copyWith(onlyNsfw: !value.onlyNsfw)),
            ),
            SizedBox(width: t.spacing.xs),
            _Pill(
              theme: t,
              icon: Icons.swap_vert_rounded,
              label: value.sort.displayName,
              active: value.sort != NsfwGallerySort.scannedAtDesc,
              onTap: () => _openSortSheet(context, t),
            ),
            if (value.activeFacetCount > 0) ...[
              SizedBox(width: t.spacing.xs),
              _Pill(
                theme: t,
                icon: Icons.clear_rounded,
                label: 'Clear',
                active: false,
                tint: t.danger,
                onTap: () => onChanged(NsfwGalleryFilter(sort: value.sort)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Labels ────────────────────────────────────────────────────────────────

  String _confidenceLabel() {
    if (value.minConfidence == 0.0 && value.maxConfidence == 1.0) {
      return 'Confidence';
    }
    final lo = (value.minConfidence * 100).round();
    final hi = (value.maxConfidence * 100).round();
    return 'Conf $lo–$hi%';
  }

  String _categoryLabel() {
    if (value.categories.length >= 5) return 'Categories';
    if (value.categories.length == 1) {
      return value.categories.first.displayName;
    }
    return '${value.categories.length} categories';
  }

  String _mediaTypeLabel() {
    if (value.mediaTypes.length >= 4) return 'Media';
    return value.mediaTypes.map((m) => m.name).join(', ');
  }

  String _dateLabel() {
    final d = value.dateRange;
    if (d == null) return 'Date';
    String fmt(DateTime dt) =>
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    return '${fmt(d.start)} → ${fmt(d.end)}';
  }

  // ── Sheets ────────────────────────────────────────────────────────────────

  Future<void> _openConfidenceSheet(BuildContext context, NsfwTheme t) async {
    final result = await showModalBottomSheet<NsfwGalleryFilter>(
      context: context,
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.spacing.xl)),
      ),
      builder: (_) =>
          _ConfidenceRangeSheet(initial: value, theme: t),
    );
    if (result != null) onChanged(result);
  }

  Future<void> _openCategorySheet(BuildContext context, NsfwTheme t) async {
    final result = await showModalBottomSheet<NsfwGalleryFilter>(
      context: context,
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.spacing.xl)),
      ),
      builder: (_) =>
          _CategoryFilterSheet(initial: value, theme: t),
    );
    if (result != null) onChanged(result);
  }

  Future<void> _openMediaTypeSheet(BuildContext context, NsfwTheme t) async {
    final result = await showModalBottomSheet<NsfwGalleryFilter>(
      context: context,
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.spacing.xl)),
      ),
      builder: (_) =>
          _MediaTypeFilterSheet(initial: value, theme: t),
    );
    if (result != null) onChanged(result);
  }

  Future<void> _openDateSheet(BuildContext context, NsfwTheme t) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: value.dateRange,
    );
    if (picked != null) {
      onChanged(value.copyWith(dateRange: picked));
    }
  }

  Future<void> _openSortSheet(BuildContext context, NsfwTheme t) async {
    final result = await showModalBottomSheet<NsfwGallerySort>(
      context: context,
      backgroundColor: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(t.spacing.xl)),
      ),
      builder: (_) => _SortSheet(current: value.sort, theme: t),
    );
    if (result != null) onChanged(value.copyWith(sort: result));
  }
}

class _Pill extends StatelessWidget {
  final NsfwTheme theme;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? tint;

  const _Pill({
    required this.theme,
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final color = tint ?? t.accent;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: t.animations.fast,
        padding: EdgeInsets.symmetric(
          horizontal: t.spacing.md,
          vertical: t.spacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.18) : t.surface,
          border: Border.all(
            color: active ? color : t.outline,
            width: active ? 1.2 : 1,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: active ? color : t.onSurfaceMuted),
              SizedBox(width: t.spacing.xs),
            ],
            Text(
              label,
              style: t.typography.body.copyWith(
                fontSize: 12,
                color: active ? color : t.onSurface,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sheets ───────────────────────────────────────────────────────────────────

class _SheetScaffold extends StatelessWidget {
  final NsfwTheme theme;
  final String title;
  final Widget child;
  final VoidCallback? onApply;
  final VoidCallback? onReset;

  const _SheetScaffold({
    required this.theme,
    required this.title,
    required this.child,
    this.onApply,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final s = t.spacing;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(s.lg, s.md, s.lg, s.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: s.md),
            Text(title, style: t.typography.title),
            SizedBox(height: s.md),
            child,
            SizedBox(height: s.md),
            Row(
              children: [
                if (onReset != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onReset,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.onSurfaceMuted,
                        side: BorderSide(color: t.outline),
                      ),
                      child: const Text('Reset'),
                    ),
                  ),
                if (onReset != null) SizedBox(width: s.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: onApply,
                    style: FilledButton.styleFrom(backgroundColor: t.accent),
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfidenceRangeSheet extends StatefulWidget {
  final NsfwGalleryFilter initial;
  final NsfwTheme theme;
  const _ConfidenceRangeSheet({required this.initial, required this.theme});

  @override
  State<_ConfidenceRangeSheet> createState() => _ConfidenceRangeSheetState();
}

class _ConfidenceRangeSheetState extends State<_ConfidenceRangeSheet> {
  late RangeValues _range;

  @override
  void initState() {
    super.initState();
    _range = RangeValues(
      widget.initial.minConfidence,
      widget.initial.maxConfidence,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return _SheetScaffold(
      theme: t,
      title: 'Confidence Range',
      child: Column(
        children: [
          RangeSlider(
            values: _range,
            min: 0,
            max: 1,
            divisions: 20,
            activeColor: t.accent,
            labels: RangeLabels(
              '${(_range.start * 100).round()}%',
              '${(_range.end * 100).round()}%',
            ),
            onChanged: (v) => setState(() => _range = v),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.spacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${(_range.start * 100).round()}%',
                    style: t.typography.body),
                Text('${(_range.end * 100).round()}%',
                    style: t.typography.body),
              ],
            ),
          ),
        ],
      ),
      onReset: () => setState(() => _range = const RangeValues(0, 1)),
      onApply: () => Navigator.of(context).pop(
        widget.initial.copyWith(
          minConfidence: _range.start,
          maxConfidence: _range.end,
        ),
      ),
    );
  }
}

class _CategoryFilterSheet extends StatefulWidget {
  final NsfwGalleryFilter initial;
  final NsfwTheme theme;
  const _CategoryFilterSheet({required this.initial, required this.theme});

  @override
  State<_CategoryFilterSheet> createState() => _CategoryFilterSheetState();
}

class _CategoryFilterSheetState extends State<_CategoryFilterSheet> {
  late Set<NsfwCategory> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initial.categories};
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return _SheetScaffold(
      theme: t,
      title: 'Categories',
      child: Wrap(
        spacing: t.spacing.sm,
        runSpacing: t.spacing.sm,
        children: NsfwCategory.values.map((c) {
          final on = _selected.contains(c);
          return FilterChip(
            label: Text(c.displayName),
            selected: on,
            selectedColor: t.accent.withValues(alpha: 0.2),
            checkmarkColor: t.accent,
            onSelected: (v) => setState(() {
              if (v) {
                _selected.add(c);
              } else {
                _selected.remove(c);
              }
            }),
          );
        }).toList(),
      ),
      onReset: () => setState(
          () => _selected = {...const NsfwGalleryFilter().categories}),
      onApply: () => Navigator.of(context).pop(
        widget.initial.copyWith(
          categories: _selected.isEmpty
              ? const NsfwGalleryFilter().categories
              : _selected,
        ),
      ),
    );
  }
}

class _MediaTypeFilterSheet extends StatefulWidget {
  final NsfwGalleryFilter initial;
  final NsfwTheme theme;
  const _MediaTypeFilterSheet({required this.initial, required this.theme});

  @override
  State<_MediaTypeFilterSheet> createState() => _MediaTypeFilterSheetState();
}

class _MediaTypeFilterSheetState extends State<_MediaTypeFilterSheet> {
  late Set<MediaType> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initial.mediaTypes};
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return _SheetScaffold(
      theme: t,
      title: 'Media Types',
      child: Wrap(
        spacing: t.spacing.sm,
        runSpacing: t.spacing.sm,
        children: const [
          MediaType.image,
          MediaType.video,
          MediaType.livePhoto,
        ].map((m) {
          final on = _selected.contains(m);
          return FilterChip(
            label: Text(m.name),
            selected: on,
            selectedColor: t.accent.withValues(alpha: 0.2),
            checkmarkColor: t.accent,
            onSelected: (v) => setState(() {
              if (v) {
                _selected.add(m);
              } else {
                _selected.remove(m);
              }
            }),
          );
        }).toList(),
      ),
      onReset: () => setState(
          () => _selected = {...const NsfwGalleryFilter().mediaTypes}),
      onApply: () => Navigator.of(context).pop(
        widget.initial.copyWith(
          mediaTypes: _selected.isEmpty
              ? const NsfwGalleryFilter().mediaTypes
              : _selected,
        ),
      ),
    );
  }
}

class _SortSheet extends StatelessWidget {
  final NsfwGallerySort current;
  final NsfwTheme theme;
  const _SortSheet({required this.current, required this.theme});

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            t.spacing.lg, t.spacing.md, t.spacing.lg, t.spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            SizedBox(height: t.spacing.md),
            Text('Sort by', style: t.typography.title),
            SizedBox(height: t.spacing.sm),
            RadioGroup<NsfwGallerySort>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) Navigator.of(context).pop(v);
              },
              child: Column(
                children: NsfwGallerySort.values
                    .map(
                      (s) => RadioListTile<NsfwGallerySort>(
                        value: s,
                        title: Text(s.displayName, style: t.typography.body),
                        activeColor: t.accent,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
