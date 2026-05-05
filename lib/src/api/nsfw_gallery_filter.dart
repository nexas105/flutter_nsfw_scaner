import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'media_item.dart';
import 'nsfw_label.dart';
import 'scan_result.dart';

/// Sorting options for [NsfwGalleryFilter] — applied AFTER filtering.
enum NsfwGallerySort {
  scannedAtDesc,
  scannedAtAsc,
  confidenceDesc,
  confidenceAsc,
  creationDateDesc,
  creationDateAsc;

  String get displayName => switch (this) {
        NsfwGallerySort.scannedAtDesc => 'Scanned (newest)',
        NsfwGallerySort.scannedAtAsc => 'Scanned (oldest)',
        NsfwGallerySort.confidenceDesc => 'Confidence (high → low)',
        NsfwGallerySort.confidenceAsc => 'Confidence (low → high)',
        NsfwGallerySort.creationDateDesc => 'Date (newest)',
        NsfwGallerySort.creationDateAsc => 'Date (oldest)',
      };
}

/// View-only filter for [NsfwGalleryView]. Original scan data is never
/// mutated — items hidden by the filter remain in the underlying buffer.
@immutable
class NsfwGalleryFilter {
  /// Inclusive top-confidence range, 0.0 – 1.0.
  final double minConfidence;
  final double maxConfidence;

  /// Categories to keep. Empty set = nothing matches; default = all known
  /// categories.
  final Set<NsfwCategory> categories;

  /// Media types to keep.
  final Set<MediaType> mediaTypes;

  /// Optional creation-date window — [MediaItem.creationDate].
  final DateTimeRange? dateRange;

  /// Convenience: when true, only items with [ScanResult.isNsfw] pass.
  final bool onlyNsfw;

  /// Sort order for surviving items.
  final NsfwGallerySort sort;

  const NsfwGalleryFilter({
    this.minConfidence = 0.0,
    this.maxConfidence = 1.0,
    this.categories = const {
      NsfwCategory.safe,
      NsfwCategory.suggestive,
      NsfwCategory.nudity,
      NsfwCategory.explicitNudity,
      NsfwCategory.unknown,
    },
    this.mediaTypes = const {
      MediaType.image,
      MediaType.video,
      MediaType.livePhoto,
      MediaType.unknown,
    },
    this.dateRange,
    this.onlyNsfw = false,
    this.sort = NsfwGallerySort.scannedAtDesc,
  });

  /// Default: passes everything, sorted scanned-at desc.
  static const NsfwGalleryFilter passthrough = NsfwGalleryFilter();

  /// Returns true when this filter is the default no-op configuration.
  bool get isPassthrough =>
      minConfidence == 0.0 &&
      maxConfidence == 1.0 &&
      categories.length == 5 &&
      mediaTypes.length == 4 &&
      dateRange == null &&
      !onlyNsfw &&
      sort == NsfwGallerySort.scannedAtDesc;

  /// Number of "active" facets (used by the UI to decide when to show a "clear"
  /// affordance). Sort is intentionally not counted.
  int get activeFacetCount {
    var n = 0;
    if (minConfidence > 0.0 || maxConfidence < 1.0) n++;
    if (categories.length < 5) n++;
    if (mediaTypes.length < 4) n++;
    if (dateRange != null) n++;
    if (onlyNsfw) n++;
    return n;
  }

  /// Apply filter + sort to a list of [ScanResult]s. Pure, non-mutating.
  List<ScanResult> apply(Iterable<ScanResult> results) {
    final filtered = <ScanResult>[];
    for (final r in results) {
      if (!_passes(r)) continue;
      filtered.add(r);
    }
    filtered.sort(_compareForSort);
    return filtered;
  }

  bool _passes(ScanResult r) {
    if (onlyNsfw && !r.isNsfw) return false;
    if (!categories.contains(r.topCategory)) return false;
    if (!mediaTypes.contains(r.item.type)) return false;
    final c = r.topConfidence;
    if (c < minConfidence || c > maxConfidence) return false;
    if (dateRange != null) {
      final d = r.item.creationDate;
      if (d == null) return false;
      if (d.isBefore(dateRange!.start) ||
          d.isAfter(dateRange!.end.add(const Duration(days: 1)))) {
        return false;
      }
    }
    return true;
  }

  int _compareForSort(ScanResult a, ScanResult b) {
    switch (sort) {
      case NsfwGallerySort.scannedAtDesc:
        return b.scannedAt.compareTo(a.scannedAt);
      case NsfwGallerySort.scannedAtAsc:
        return a.scannedAt.compareTo(b.scannedAt);
      case NsfwGallerySort.confidenceDesc:
        return b.topConfidence.compareTo(a.topConfidence);
      case NsfwGallerySort.confidenceAsc:
        return a.topConfidence.compareTo(b.topConfidence);
      case NsfwGallerySort.creationDateDesc:
        final ad = a.item.creationDate;
        final bd = b.item.creationDate;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      case NsfwGallerySort.creationDateAsc:
        final ad = a.item.creationDate;
        final bd = b.item.creationDate;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return ad.compareTo(bd);
    }
  }

  NsfwGalleryFilter copyWith({
    double? minConfidence,
    double? maxConfidence,
    Set<NsfwCategory>? categories,
    Set<MediaType>? mediaTypes,
    DateTimeRange? dateRange,
    bool clearDateRange = false,
    bool? onlyNsfw,
    NsfwGallerySort? sort,
  }) =>
      NsfwGalleryFilter(
        minConfidence: minConfidence ?? this.minConfidence,
        maxConfidence: maxConfidence ?? this.maxConfidence,
        categories: categories ?? this.categories,
        mediaTypes: mediaTypes ?? this.mediaTypes,
        dateRange: clearDateRange ? null : (dateRange ?? this.dateRange),
        onlyNsfw: onlyNsfw ?? this.onlyNsfw,
        sort: sort ?? this.sort,
      );

  Map<String, dynamic> toJson() => {
        'minConfidence': minConfidence,
        'maxConfidence': maxConfidence,
        'categories': categories.map((c) => c.name).toList(),
        'mediaTypes': mediaTypes.map((m) => m.name).toList(),
        if (dateRange != null)
          'dateRange': {
            'start': dateRange!.start.millisecondsSinceEpoch,
            'end': dateRange!.end.millisecondsSinceEpoch,
          },
        'onlyNsfw': onlyNsfw,
        'sort': sort.name,
      };

  factory NsfwGalleryFilter.fromJson(Map<String, dynamic> json) {
    Set<NsfwCategory> parseCategories() {
      final raw = json['categories'];
      if (raw is! List) return const NsfwGalleryFilter().categories;
      return raw
          .whereType<String>()
          .map((s) => NsfwCategory.values.firstWhere(
                (c) => c.name == s,
                orElse: () => NsfwCategory.unknown,
              ))
          .toSet();
    }

    Set<MediaType> parseMediaTypes() {
      final raw = json['mediaTypes'];
      if (raw is! List) return const NsfwGalleryFilter().mediaTypes;
      return raw
          .whereType<String>()
          .map((s) => MediaType.values.firstWhere(
                (m) => m.name == s,
                orElse: () => MediaType.unknown,
              ))
          .toSet();
    }

    DateTimeRange? parseDateRange() {
      final raw = json['dateRange'];
      if (raw is! Map) return null;
      final start = raw['start'];
      final end = raw['end'];
      if (start is! int || end is! int) return null;
      return DateTimeRange(
        start: DateTime.fromMillisecondsSinceEpoch(start),
        end: DateTime.fromMillisecondsSinceEpoch(end),
      );
    }

    NsfwGallerySort parseSort() {
      final s = json['sort'];
      if (s is! String) return NsfwGallerySort.scannedAtDesc;
      return NsfwGallerySort.values.firstWhere(
        (v) => v.name == s,
        orElse: () => NsfwGallerySort.scannedAtDesc,
      );
    }

    return NsfwGalleryFilter(
      minConfidence: (json['minConfidence'] as num?)?.toDouble() ?? 0.0,
      maxConfidence: (json['maxConfidence'] as num?)?.toDouble() ?? 1.0,
      categories: parseCategories(),
      mediaTypes: parseMediaTypes(),
      dateRange: parseDateRange(),
      onlyNsfw: json['onlyNsfw'] as bool? ?? false,
      sort: parseSort(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NsfwGalleryFilter) return false;
    return minConfidence == other.minConfidence &&
        maxConfidence == other.maxConfidence &&
        setEquals(categories, other.categories) &&
        setEquals(mediaTypes, other.mediaTypes) &&
        dateRange == other.dateRange &&
        onlyNsfw == other.onlyNsfw &&
        sort == other.sort;
  }

  @override
  int get hashCode => Object.hash(
        minConfidence,
        maxConfidence,
        Object.hashAllUnordered(categories),
        Object.hashAllUnordered(mediaTypes),
        dateRange,
        onlyNsfw,
        sort,
      );
}

/// A bulk action consumers can register on [NsfwGalleryView] when
/// `enableSelection: true`. The plugin renders the action chip; the consumer
/// performs the work in [onInvoke].
@immutable
class NsfwBulkAction {
  final String label;
  final IconData icon;
  final void Function(List<ScanResult> selected) onInvoke;
  final Color? tint;

  const NsfwBulkAction({
    required this.label,
    required this.icon,
    required this.onInvoke,
    this.tint,
  });
}
