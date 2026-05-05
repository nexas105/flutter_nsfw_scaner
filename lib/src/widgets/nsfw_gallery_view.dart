import 'dart:async';
import 'package:flutter/material.dart';
import '../api/media_item.dart';
import '../api/nsfw_gallery_filter.dart';
import '../api/scan_result.dart';
import '../api/scan_progress.dart';
import '../api/scan_summary.dart';
import '../api/scan_configuration.dart';
import '../api/scan_session.dart';
import '../api/nsfw_detector.dart';
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

class NsfwGalleryView extends StatefulWidget {
  final ScanConfiguration initialConfig;
  final NsfwGalleryTheme theme;
  final NsfwTheme? designTheme;
  final NsfwMediaTileBuilder? tileBuilder;
  /// Optional builder for thumbnail images. Called per-item during grid
  /// rendering. When set, the returned widget replaces the default grey
  /// placeholder inside [NsfwMediaTile]. Use this to inject real photo
  /// thumbnails from a photo-library package in the host application.
  ///
  /// Example (with photo_manager):
  /// ```dart
  /// thumbnailBuilder: (context, item) => AssetEntityImage(
  ///   AssetEntity(id: item.localIdentifier, typeInt: 1, width: 200, height: 200),
  ///   isOriginal: false,
  ///   thumbnailSize: const ThumbnailSize.square(200),
  ///   fit: BoxFit.cover,
  /// ),
  /// ```
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

  /// View-only filter applied on top of the scanned items. The underlying
  /// buffer is never mutated; toggling [filter] simply changes which results
  /// the grid shows. Defaults to passthrough.
  final NsfwGalleryFilter? filter;

  /// When true, render a [NsfwFilterBar] above the grid. Set [filter] /
  /// [onFilterChanged] together with this flag — the host owns the filter
  /// state.
  final bool showFilterBar;

  /// Emitted whenever the user changes the filter via [NsfwFilterBar]. If
  /// null, the bar still mutates the internal default filter.
  final ValueChanged<NsfwGalleryFilter>? onFilterChanged;

  /// When true, render a [NsfwSearchField] above the grid. Search matches
  /// against `MediaItem.localIdentifier` and `result.topCategory.displayName`.
  final bool showSearchField;

  /// Multi-select opt-in. When true:
  ///   * Long-press toggles selection mode + selects the tile.
  ///   * Subsequent taps in selection-mode toggle each tile.
  ///   * The [NsfwScanControls] strip is replaced by [NsfwSelectionToolbar]
  ///     showing the [bulkActions].
  final bool enableSelection;

  /// Bulk actions shown in the selection toolbar. Empty list still allows
  /// selection but renders no actions (host can read selection via
  /// [onSelectionChanged]).
  final List<NsfwBulkAction> bulkActions;

  /// Notified whenever the active selection changes. Empty set means
  /// selection mode is off (or just emptied — the toolbar exits automatically).
  final ValueChanged<Set<String>>? onSelectionChanged;

  const NsfwGalleryView({
    super.key,
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
  PhotoLibraryPermissionStatus? _permissionStatus;
  ScanSession? _session;
  late ScanConfiguration _config;
  ScanProgress? _lastProgress;

  // Ordered list of all items we've seen (inserted as results arrive)
  final List<MediaItem> _items = [];
  // Map from localIdentifier -> ScanResult
  final Map<String, ScanResult> _results = {};

  StreamSubscription<ScanResult>? _resultSub;
  StreamSubscription<ScanProgress>? _progressSub;

  final _progressStreamController = StreamController<ScanProgress>.broadcast();

  // ── Stage 2 state ─────────────────────────────────────────────────────────
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
    _config = widget.initialConfig;
    _internalFilter = widget.filter ?? NsfwGalleryFilter.passthrough;
    _checkPermission();
  }

  @override
  void didUpdateWidget(covariant NsfwGalleryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _config = widget.initialConfig;
    if (widget.filter != null && widget.filter != _internalFilter) {
      _internalFilter = widget.filter!;
    }
    if (!widget.enableSelection && _selectionMode) {
      _exitSelection();
    }
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    _progressSub?.cancel();
    _progressStreamController.close();
    _session?.cancel();
    super.dispose();
  }

  Future<void> _checkPermission() async {
    final status = await NsfwDetector.instance.checkPermission();
    if (mounted) {
      setState(() => _permissionStatus = status);
      if (widget.autoStartOnPermission &&
          (status == PhotoLibraryPermissionStatus.authorized ||
              status == PhotoLibraryPermissionStatus.limited)) {
        _startScan();
      }
    }
  }

  Future<void> _requestPermission() async {
    final status = await NsfwDetector.instance.requestPermission();
    if (mounted) {
      setState(() => _permissionStatus = status);
      if (status == PhotoLibraryPermissionStatus.authorized ||
          status == PhotoLibraryPermissionStatus.limited) {
        _startScan();
      }
    }
  }

  bool _wasStopped = false;

  Future<void> _startScan({bool resume = false}) async {
    if (_session?.isRunning == true) return;

    if (!resume) {
      setState(() {
        _items.clear();
        _results.clear();
        _lastProgress = null;
        _wasStopped = false;
      });
    } else {
      setState(() => _wasStopped = false);
    }

    final scanConfig = resume
        ? _config.copyWith(resumeFromCheckpoint: true)
        : _config;

    final session = await NsfwDetector.instance.startScan(scanConfig);
    setState(() => _session = session);

    _resultSub?.cancel();
    _progressSub?.cancel();

    _resultSub = session.results.listen((result) {
      if (!mounted) return;
      setState(() {
        if (!_results.containsKey(result.item.localIdentifier)) {
          _items.add(result.item);
        }
        _results[result.item.localIdentifier] = result;
      });
    });

    _progressSub = session.progress.listen((p) {
      if (!mounted) return;
      setState(() => _lastProgress = p);
      _progressStreamController.add(p);
    });

    session.done.then((summary) {
      if (mounted) {
        setState(() {});
        widget.onScanComplete?.call(summary);
      }
    });
  }

  Future<void> _stopScan() async {
    await _session?.cancel();
    if (mounted) setState(() => _wasStopped = true);
  }

  Future<void> _onPullRefresh() async {
    if (_session?.isRunning == true) return;
    await _startScan();
  }

  void updateConfig(ScanConfiguration config) {
    setState(() => _config = config);
  }

  // ── Selection helpers ─────────────────────────────────────────────────────

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

  List<ScanResult> get _selectedResults => _selectedIds
      .map((id) => _results[id])
      .whereType<ScanResult>()
      .toList(growable: false);

  // ── View-only filter / search ─────────────────────────────────────────────

  List<ScanResult> _computeVisibleResults() {
    final all = _items
        .map((it) => _results[it.localIdentifier])
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isScanning = _session?.isRunning == true;
    final t = _designTheme;

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
          if (widget.showProgressBar && (isScanning || _lastProgress != null))
            Padding(
              padding: EdgeInsets.fromLTRB(
                  t.spacing.md, 0, t.spacing.md, t.spacing.sm),
              child: NsfwScanProgressBar(
                progressStream: _progressStreamController.stream,
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
        selectedResults: _selectedResults,
        actions: widget.bulkActions
            .map(
              (a) => NsfwBulkAction(
                label: a.label,
                icon: a.icon,
                tint: a.tint,
                onInvoke: (results) {
                  a.onInvoke(results);
                  // Auto-exit after invoke so the user sees a fresh state.
                  _exitSelection();
                },
              ),
            )
            .toList(growable: false),
        onExit: _exitSelection,
      );
    }
    if (_wasStopped && !isScanning) {
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
              onPressed: () => _startScan(),
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
      onStart: _permissionStatus == null
          ? _requestPermission
          : () => _startScan(),
      onStop: isScanning ? _stopScan : null,
    );
  }

  Widget _body(NsfwTheme t) {
    if (_permissionStatus == PhotoLibraryPermissionStatus.denied ||
        _permissionStatus == PhotoLibraryPermissionStatus.restricted) {
      return widget.permissionDeniedWidget ?? _defaultPermissionDenied(t);
    }
    if (_permissionStatus == null ||
        _permissionStatus == PhotoLibraryPermissionStatus.notDetermined) {
      return _defaultPermissionRequest(t);
    }
    final isScanning = _session?.isRunning == true;
    if (_items.isEmpty) {
      if (isScanning) {
        return NsfwSkeletonGrid(theme: t, crossAxisCount: widget.crossAxisCount);
      }
      return widget.emptyStateWidget ?? _defaultEmpty(t);
    }
    final visible = _computeVisibleResults();
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

    if (!widget.enablePullToRefresh || _session?.isRunning == true) return grid;
    return RefreshIndicator(
      color: t.accent,
      backgroundColor: t.surface,
      onRefresh: _onPullRefresh,
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

  // ── Empty / permission states ──────────────────────────────────────────────

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
          onPressed: _requestPermission,
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: const Text('Grant Access'),
          style: FilledButton.styleFrom(backgroundColor: t.accent),
        ),
      );

  Widget _defaultPermissionDenied(NsfwTheme t) => _stateScaffold(
        t,
        icon: Icons.no_photography_outlined,
        headline: 'Photo access denied',
        subtitle: 'Allow access in Settings → Privacy → Photos to start a scan.',
        iconColor: t.danger,
      );
}
