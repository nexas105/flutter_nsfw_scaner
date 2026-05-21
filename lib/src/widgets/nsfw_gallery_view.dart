import 'dart:async';

import 'package:flutter/material.dart';
import '../api/media_item.dart';
import '../api/nsfw_gallery_filter.dart';
import '../api/nsfw_scan_controller.dart';
import '../api/scan_result.dart';
import '../api/scan_summary.dart';
import '../api/scan_configuration.dart';
import '../platform/nsfw_platform_interface.dart';
import 'nsfw_filter_bar.dart';
import 'nsfw_media_tile.dart';
import 'nsfw_result_badge.dart';
import 'nsfw_scan_progress_bar.dart';
import 'nsfw_scan_controls.dart';
import 'nsfw_search_field.dart';
import 'nsfw_selection_toolbar.dart';
import 'nsfw_skeleton_tile.dart';
import 'theme/nsfw_theme.dart';

/// Pre-built photo-library scan UI backed by a [NsfwScanController].
///
/// The widget handles permission probing, scan controls, progress display,
/// filtering, search, optional selection, and result tiles. It does not fetch
/// real thumbnails by itself; provide [thumbnailBuilder] when the host app
/// wants to render photo-library previews.
///
/// When [controller] is null (the default — backwards-compatible behaviour),
/// the widget creates and owns an internal [NsfwScanController] for the
/// duration of its lifetime and disposes it on unmount. When [controller]
/// is provided by the host, lifetime + disposal are the host's
/// responsibility.
///
/// Filter / search / selection state remain in the widget — those are
/// view-level concerns. Hosts that want to lift them up are expected to
/// drive the [filter] / [onFilterChanged] / [onSelectionChanged] hooks.
///
/// Scan labels are probabilistic. The optional blur and badge UI are
/// presentation choices, not a promise that all sensitive content is detected.
class NsfwGalleryView extends StatefulWidget {
  /// Optional external controller. If null the widget creates its own.
  final NsfwScanController? controller;

  /// Used only when [controller] is null — the internally-created controller
  /// is initialised with this configuration.
  final ScanConfiguration initialConfig;

  final NsfwGalleryTheme theme;
  final NsfwTheme? designTheme;
  final NsfwMediaTileBuilder? tileBuilder;

  /// Optional builder for thumbnail images. Called per-item during grid
  /// rendering. When set, the returned widget replaces the default grey
  /// placeholder inside [NsfwMediaTile]. Use this to inject real photo
  /// thumbnails from a photo-library package in the host application.
  final Widget Function(BuildContext context, MediaItem item)? thumbnailBuilder;
  final BadgeStyle badgeStyle;
  final void Function(ScanResult)? onResultTap;
  final void Function(ScanSummary)? onScanComplete;
  final Widget? emptyStateWidget;
  final Widget? permissionDeniedWidget;
  final Widget? scanningWidget;
  final int crossAxisCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final bool showControls;
  final bool showProgressBar;
  final bool blurNsfwTiles;
  final bool autoStartOnPermission;
  final bool enablePullToRefresh;

  /// View-only filter applied on top of the scanned items.
  final NsfwGalleryFilter? filter;

  /// When true, render a [NsfwFilterBar] above the grid.
  final bool showFilterBar;

  /// Emitted whenever the user changes the filter via [NsfwFilterBar].
  final ValueChanged<NsfwGalleryFilter>? onFilterChanged;

  /// When true, render a [NsfwSearchField] above the grid.
  final bool showSearchField;

  /// Multi-select opt-in.
  final bool enableSelection;

  /// Bulk actions shown in the selection toolbar.
  final List<NsfwBulkAction> bulkActions;

  /// Notified whenever the active selection changes.
  final ValueChanged<Set<String>>? onSelectionChanged;

  const NsfwGalleryView({
    super.key,
    this.controller,
    this.initialConfig = const ScanConfiguration(),
    this.theme = NsfwGalleryTheme.defaults,
    this.designTheme,
    this.tileBuilder,
    this.thumbnailBuilder,
    this.badgeStyle = BadgeStyle.compact,
    this.onResultTap,
    this.onScanComplete,
    this.emptyStateWidget,
    this.permissionDeniedWidget,
    this.scanningWidget,
    this.crossAxisCount = 3,
    this.crossAxisSpacing = 2,
    this.mainAxisSpacing = 2,
    this.showControls = true,
    this.showProgressBar = true,
    this.blurNsfwTiles = false,
    this.autoStartOnPermission = false,
    this.enablePullToRefresh = true,
    this.filter,
    this.showFilterBar = false,
    this.onFilterChanged,
    this.showSearchField = false,
    this.enableSelection = false,
    this.bulkActions = const [],
    this.onSelectionChanged,
  });

  @override
  State<NsfwGalleryView> createState() => _NsfwGalleryViewState();
}

class _NsfwGalleryViewState extends State<NsfwGalleryView> {
  late NsfwScanController _controller;
  bool _ownsController = false;

  // ── View-only state ───────────────────────────────────────────────────
  late NsfwGalleryFilter _internalFilter;
  String _searchQuery = '';
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  NsfwGalleryFilter get _activeFilter => widget.filter ?? _internalFilter;

  NsfwTheme get _designTheme =>
      widget.designTheme ?? NsfwTheme.dark(gallery: widget.theme);

  @override
  void initState() {
    super.initState();
    _internalFilter = widget.filter ?? NsfwGalleryFilter.passthrough;
    _bindController();
    // Kick off the same permission probe the previous god-widget did.
    _controller.checkPermission();
  }

  void _bindController() {
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = NsfwScanController(
        initialConfig: widget.initialConfig,
        autoStartOnPermission: widget.autoStartOnPermission,
      );
      _ownsController = true;
    }
  }

  @override
  void didUpdateWidget(covariant NsfwGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      // Swap controller. Dispose the previous one if we owned it.
      if (_ownsController) {
        _controller.dispose();
      }
      _bindController();
      _controller.checkPermission();
    } else if (widget.controller == null &&
        widget.initialConfig != oldWidget.initialConfig) {
      // Internal controller — propagate config changes.
      _controller.updateConfig(widget.initialConfig);
    }
    if (widget.filter != null && widget.filter != _internalFilter) {
      _internalFilter = widget.filter!;
    }
    if (!widget.enableSelection && _selectionMode) {
      _exitSelection();
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  Future<void> _onScanCompleteWatcher() async {
    final session = _controller.session;
    if (session == null) return;
    final summary = await session.done;
    if (mounted) widget.onScanComplete?.call(summary);
  }

  // ── Selection helpers ─────────────────────────────────────────────────

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(_selectedIds));
  }

  void _enterSelection(String id) {
    if (!widget.enableSelection) return;
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(_selectedIds));
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    widget.onSelectionChanged?.call(const <String>{});
  }

  List<ScanResult> _selectedResults(Map<String, ScanResult> results) =>
      _selectedIds
          .map((id) => results[id])
          .whereType<ScanResult>()
          .toList(growable: false);

  // ── View-only filter / search ─────────────────────────────────────────

  List<ScanResult> _computeVisibleResults(
      List<MediaItem> items, Map<String, ScanResult> results) {
    final all = items
        .map((it) => results[it.localIdentifier])
        .whereType<ScanResult>()
        .toList(growable: false);
    final filtered = _activeFilter.apply(all);
    if (_searchQuery.isEmpty) return filtered;
    final q = _searchQuery;
    return filtered.where((r) {
      final id = r.item.localIdentifier.toLowerCase();
      final cat = r.topCategory.displayName.toLowerCase();
      return id.contains(q) || cat.contains(q);
    }).toList(growable: false);
  }

  void _onFilterChanged(NsfwGalleryFilter next) {
    if (widget.filter == null) {
      setState(() => _internalFilter = next);
    }
    widget.onFilterChanged?.call(next);
  }

  Future<void> _startScan({bool resume = false}) async {
    await _controller.startScan(resume: resume);
    // Fire onScanComplete once the session reports done. Fire-and-forget —
    // _onScanCompleteWatcher disposes itself on widget teardown, and we
    // don't want to block the button handler on the whole scan run.
    unawaited(_onScanCompleteWatcher());
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => _buildBody(),
    );
  }

  Widget _buildBody() {
    final t = _designTheme;
    final isScanning = _controller.isScanning;

    return Container(
      color: widget.theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          if (widget.showControls)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  t.spacing.md, t.spacing.sm, t.spacing.md, t.spacing.xs),
              child: _topBar(t, isScanning),
            ),
          if (widget.showSearchField && !_selectionMode)
            NsfwSearchField(
              theme: t,
              onChanged: (q) => setState(() => _searchQuery = q),
            ),
          if (widget.showFilterBar && !_selectionMode)
            NsfwFilterBar(
              theme: t,
              value: _activeFilter,
              onChanged: _onFilterChanged,
            ),
          if (widget.showProgressBar &&
              (isScanning || _controller.lastProgress != null))
            Padding(
              padding: EdgeInsets.fromLTRB(
                  t.spacing.md, 0, t.spacing.md, t.spacing.sm),
              child: NsfwScanProgressBar(
                progressStream: _controller.progressStream,
                theme: widget.theme,
              ),
            ),
          Expanded(child: _body(t)),
        ],
      ),
    );
  }

  Widget _topBar(NsfwTheme t, bool isScanning) {
    if (_selectionMode) {
      return NsfwSelectionToolbar(
        theme: t,
        selectedCount: _selectedIds.length,
        selectedResults: _selectedResults(_controller.results),
        actions: widget.bulkActions
            .map(
              (a) => NsfwBulkAction(
                label: a.label,
                icon: a.icon,
                tint: a.tint,
                onInvoke: (results) {
                  a.onInvoke(results);
                  _exitSelection();
                },
              ),
            )
            .toList(growable: false),
        onExit: _exitSelection,
      );
    }
    if (_controller.wasStopped && !isScanning) {
      return Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => _startScan(resume: true),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Resume'),
              style: FilledButton.styleFrom(
                backgroundColor: t.success,
              ),
            ),
          ),
          SizedBox(width: t.spacing.sm),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('New Scan'),
              style: OutlinedButton.styleFrom(
                foregroundColor: t.onSurfaceMuted,
                side: BorderSide(color: t.outline),
              ),
            ),
          ),
        ],
      );
    }
    return NsfwScanControls(
      isScanning: isScanning,
      onStart: _controller.permissionStatus == null
          ? _controller.requestPermission
          : _startScan,
      onStop: isScanning ? _controller.stopScan : null,
    );
  }

  Widget _body(NsfwTheme t) {
    final status = _controller.permissionStatus;
    if (status == PhotoLibraryPermissionStatus.denied ||
        status == PhotoLibraryPermissionStatus.restricted) {
      return widget.permissionDeniedWidget ?? _defaultPermissionDenied(t);
    }
    if (status == null ||
        status == PhotoLibraryPermissionStatus.notDetermined) {
      return _defaultPermissionRequest(t);
    }
    final isScanning = _controller.isScanning;
    final items = _controller.items;
    final results = _controller.results;
    if (items.isEmpty) {
      if (isScanning) {
        return NsfwSkeletonGrid(
            theme: t, crossAxisCount: widget.crossAxisCount);
      }
      return widget.emptyStateWidget ?? _defaultEmpty(t);
    }
    final visible = _computeVisibleResults(items, results);
    if (visible.isEmpty) return _defaultNoMatches(t);
    return _grid(t, visible);
  }

  Widget _grid(NsfwTheme t, List<ScanResult> visible) {
    final grid = GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.crossAxisCount,
        crossAxisSpacing: widget.crossAxisSpacing,
        mainAxisSpacing: widget.mainAxisSpacing,
        childAspectRatio: 1,
      ),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final result = visible[index];
        final item = result.item;
        final id = item.localIdentifier;
        final isSelected = _selectedIds.contains(id);
        final tile = widget.tileBuilder != null
            ? widget.tileBuilder!(
                context,
                item,
                result,
                NsfwMediaTile(
                  item: item,
                  result: result,
                  theme: widget.theme,
                  selected: isSelected,
                  selectable: _selectionMode,
                ),
              )
            : NsfwMediaTile(
                key: ValueKey(id),
                item: item,
                result: result,
                theme: widget.theme,
                badgeStyle: widget.badgeStyle,
                blurNsfw: widget.blurNsfwTiles,
                selected: isSelected,
                selectable: _selectionMode,
                onTap: () {
                  if (_selectionMode) {
                    _toggleSelection(id);
                  } else {
                    widget.onResultTap?.call(result);
                  }
                },
                onLongPress: widget.enableSelection
                    ? () {
                        if (_selectionMode) {
                          _toggleSelection(id);
                        } else {
                          _enterSelection(id);
                        }
                      }
                    : null,
                thumbnailWidget: widget.thumbnailBuilder?.call(context, item),
              );
        return AnimatedSwitcher(
          duration: t.animations.normal,
          switchInCurve: t.animations.curve,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: KeyedSubtree(
            key: ValueKey(id),
            child: tile,
          ),
        );
      },
    );

    if (!widget.enablePullToRefresh || _controller.isScanning) return grid;
    return RefreshIndicator(
      color: t.accent,
      backgroundColor: t.surface,
      onRefresh: _startScan,
      child: grid,
    );
  }

  Widget _defaultNoMatches(NsfwTheme t) => _stateScaffold(
        t,
        icon: Icons.filter_list_off_rounded,
        headline: 'No matches',
        subtitle: _searchQuery.isNotEmpty
            ? 'Search "$_searchQuery" matched zero items.'
            : 'No items match the current filter.',
        iconColor: t.onSurfaceMuted,
      );

  // ── Empty / permission states ──────────────────────────────────────────

  Widget _stateScaffold(
    NsfwTheme t, {
    required IconData icon,
    required String headline,
    required String subtitle,
    required Color iconColor,
    Widget? action,
  }) =>
      Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: iconColor.withValues(alpha: 0.12),
                ),
                child: Icon(icon, size: 48, color: iconColor),
              ),
              SizedBox(height: t.spacing.lg),
              Text(
                headline,
                style: t.typography.title,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: t.spacing.sm),
              Text(
                subtitle,
                style: t.typography.caption,
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[
                SizedBox(height: t.spacing.lg),
                action,
              ],
            ],
          ),
        ),
      );

  Widget _defaultEmpty(NsfwTheme t) => _stateScaffold(
        t,
        icon: Icons.photo_library_outlined,
        headline: 'Library is empty',
        subtitle: 'Tap "Scan Library" to start classifying photos and videos.',
        iconColor: t.onSurfaceMuted,
      );

  Widget _defaultPermissionRequest(NsfwTheme t) => _stateScaffold(
        t,
        icon: Icons.lock_outline_rounded,
        headline: 'Photo library access needed',
        subtitle: 'NSFW Detect scans your photos and videos on-device — '
            'nothing leaves the phone.',
        iconColor: t.accent,
        action: FilledButton.icon(
          onPressed: _controller.requestPermission,
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: const Text('Grant Access'),
          style: FilledButton.styleFrom(backgroundColor: t.accent),
        ),
      );

  Widget _defaultPermissionDenied(NsfwTheme t) => _stateScaffold(
        t,
        icon: Icons.no_photography_outlined,
        headline: 'Photo access denied',
        subtitle:
            'Allow access in Settings → Privacy → Photos to start a scan.',
        iconColor: t.danger,
      );
}
