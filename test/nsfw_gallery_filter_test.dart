import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

ScanResult _result({
  required String id,
  NsfwCategory cat = NsfwCategory.safe,
  double conf = 0.95,
  MediaType type = MediaType.image,
  DateTime? created,
  DateTime? scanned,
}) =>
    ScanResult(
      item: MediaItem(
        localIdentifier: id,
        type: type,
        creationDate: created,
      ),
      status: ScanStatus.completed,
      labels: [
        NsfwLabel(category: cat, confidence: conf),
        NsfwLabel(
            category: cat == NsfwCategory.safe
                ? NsfwCategory.nudity
                : NsfwCategory.safe,
            confidence: 1 - conf),
      ],
      scannedAt: scanned ?? DateTime(2026, 1, 1),
      confidenceThreshold: 0.7,
    );

void main() {
  group('NsfwGalleryFilter', () {
    test('passthrough keeps everything', () {
      final all = [
        _result(id: 'a', cat: NsfwCategory.safe, conf: 0.9),
        _result(id: 'b', cat: NsfwCategory.nudity, conf: 0.8),
        _result(id: 'c', cat: NsfwCategory.suggestive, conf: 0.6),
      ];
      final out = const NsfwGalleryFilter().apply(all);
      expect(out, hasLength(3));
    });

    test('confidence range filters by topConfidence', () {
      final items = [
        _result(id: 'a', conf: 0.95),
        _result(id: 'b', conf: 0.5),
        _result(id: 'c', conf: 0.2),
      ];
      final filtered = const NsfwGalleryFilter(minConfidence: 0.4)
          .apply(items)
          .map((r) => r.item.localIdentifier)
          .toSet();
      expect(filtered, {'a', 'b'});
    });

    test('onlyNsfw drops safe items', () {
      final items = [
        _result(id: 'safe', cat: NsfwCategory.safe, conf: 0.99),
        _result(id: 'nsfw', cat: NsfwCategory.nudity, conf: 0.99),
      ];
      final filtered =
          const NsfwGalleryFilter(onlyNsfw: true).apply(items);
      expect(filtered, hasLength(1));
      expect(filtered.first.item.localIdentifier, 'nsfw');
    });

    test('mediaTypes filter excludes videos when only image is selected', () {
      final items = [
        _result(id: 'p', type: MediaType.image),
        _result(id: 'v', type: MediaType.video),
      ];
      final filtered = const NsfwGalleryFilter(mediaTypes: {MediaType.image})
          .apply(items)
          .map((r) => r.item.localIdentifier);
      expect(filtered, ['p']);
    });

    test('confidenceDesc sort orders highest first', () {
      final items = [
        _result(id: 'b', conf: 0.5),
        _result(id: 'c', conf: 0.2),
        _result(id: 'a', conf: 0.9),
      ];
      final sorted = const NsfwGalleryFilter(sort: NsfwGallerySort.confidenceDesc)
          .apply(items)
          .map((r) => r.item.localIdentifier)
          .toList();
      expect(sorted, ['a', 'b', 'c']);
    });

    test('creationDateAsc keeps null dates last', () {
      final items = [
        _result(id: 'old', created: DateTime(2020)),
        _result(id: 'new', created: DateTime(2025)),
        _result(id: 'unknown'),
      ];
      final sorted = const NsfwGalleryFilter(
              sort: NsfwGallerySort.creationDateAsc)
          .apply(items)
          .map((r) => r.item.localIdentifier)
          .toList();
      expect(sorted, ['old', 'new', 'unknown']);
    });

    test('copyWith preserves untouched fields', () {
      const original =
          NsfwGalleryFilter(minConfidence: 0.4, onlyNsfw: true);
      final copy = original.copyWith(maxConfidence: 0.9);
      expect(copy.minConfidence, 0.4);
      expect(copy.maxConfidence, 0.9);
      expect(copy.onlyNsfw, true);
    });

    test('clearDateRange removes the existing range', () {
      final base = NsfwGalleryFilter(
        dateRange: DateTimeRange(
          start: DateTime(2024),
          end: DateTime(2025),
        ),
      );
      final cleared = base.copyWith(clearDateRange: true);
      expect(cleared.dateRange, isNull);
    });

    test('equality + hashCode are based on facet values', () {
      const a = NsfwGalleryFilter(minConfidence: 0.5);
      const b = NsfwGalleryFilter(minConfidence: 0.5);
      const c = NsfwGalleryFilter(minConfidence: 0.6);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, false);
    });

    test('JSON round-trip preserves all facets', () {
      final f = NsfwGalleryFilter(
        minConfidence: 0.3,
        maxConfidence: 0.9,
        categories: const {NsfwCategory.safe, NsfwCategory.nudity},
        mediaTypes: const {MediaType.image},
        dateRange:
            DateTimeRange(start: DateTime(2024), end: DateTime(2025)),
        onlyNsfw: true,
        sort: NsfwGallerySort.confidenceAsc,
      );
      final restored = NsfwGalleryFilter.fromJson(f.toJson());
      expect(restored, f);
    });

    test('activeFacetCount counts only non-default facets', () {
      expect(const NsfwGalleryFilter().activeFacetCount, 0);
      expect(const NsfwGalleryFilter(onlyNsfw: true).activeFacetCount, 1);
      expect(
        const NsfwGalleryFilter(
          minConfidence: 0.5,
          mediaTypes: {MediaType.image},
        ).activeFacetCount,
        2,
      );
    });
  });
}
