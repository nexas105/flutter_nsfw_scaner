import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('ScanResult convenience getters', () {
    test('safe item has no NSFW flags', () {
      final r = ScanResult.fake(category: NsfwCategory.safe, confidence: 0.95);
      expect(r.isNsfw, isFalse);
      expect(r.hasNudity, isFalse);
      expect(r.hasExplicitContent, isFalse);
      expect(r.isSuggestive, isFalse);
      expect(r.isSafe, isTrue);
    });

    test('explicit + above threshold → hasExplicitContent', () {
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.92,
      );
      expect(r.isNsfw, isTrue);
      expect(r.hasExplicitContent, isTrue);
      expect(r.hasNudity, isFalse);
    });

    test('nudity below threshold doesn\'t trip hasNudity', () {
      final r = ScanResult.fake(
        category: NsfwCategory.nudity,
        confidence: 0.5,
        confidenceThreshold: 0.7,
      );
      expect(r.hasNudity, isFalse);
      expect(r.isNsfw, isFalse);
    });

    test('confidenceDescription buckets', () {
      expect(
        ScanResult.fake(confidence: 0.95).confidenceDescription,
        'Very high',
      );
      expect(
        ScanResult.fake(confidence: 0.8).confidenceDescription,
        'High',
      );
      expect(
        ScanResult.fake(confidence: 0.65).confidenceDescription,
        'Moderate',
      );
      expect(
        ScanResult.fake(confidence: 0.5).confidenceDescription,
        'Low',
      );
      expect(
        ScanResult.fake(confidence: 0.1).confidenceDescription,
        'Very low',
      );
    });

    test('toJson / fromJson round-trip', () {
      final r = ScanResult.fake(
        localIdentifier: 'abc-123',
        category: NsfwCategory.nudity,
        confidence: 0.82,
        confidenceThreshold: 0.75,
      );
      final restored = ScanResult.fromJson(r.toJson());
      expect(restored.item.localIdentifier, r.item.localIdentifier);
      expect(restored.topCategory, r.topCategory);
      expect(restored.topConfidence, closeTo(r.topConfidence, 1e-9));
      expect(restored.confidenceThreshold, r.confidenceThreshold);
      expect(restored.isNsfw, r.isNsfw);
    });

    test('failed factory carries error message', () {
      final r = ScanResult.failed(
        localIdentifier: 'broken',
        errorMessage: 'oops',
      );
      expect(r.status, ScanStatus.failed);
      expect(r.errorMessage, 'oops');
      expect(r.isNsfw, isFalse);
      expect(r.isSafe, isFalse);
    });
  });

  group('PhotoLibraryPermissionStatus extension', () {
    test('canScan / needsSettingsApp', () {
      expect(PhotoLibraryPermissionStatus.authorized.canScan, isTrue);
      expect(PhotoLibraryPermissionStatus.limited.canScan, isTrue);
      expect(PhotoLibraryPermissionStatus.denied.canScan, isFalse);
      expect(
        PhotoLibraryPermissionStatus.denied.needsSettingsApp,
        isTrue,
      );
      expect(
        PhotoLibraryPermissionStatus.notDetermined.needsSettingsApp,
        isFalse,
      );
    });
  });

  group('ScanResult list extensions', () {
    test('countByCategory', () {
      final list = [
        ScanResult.fake(localIdentifier: '1', category: NsfwCategory.safe),
        ScanResult.fake(localIdentifier: '2', category: NsfwCategory.safe),
        ScanResult.fake(localIdentifier: '3', category: NsfwCategory.nudity),
      ];
      expect(list.countByCategory[NsfwCategory.safe], 2);
      expect(list.countByCategory[NsfwCategory.nudity], 1);
    });

    test('newSince + changedFrom', () {
      final yesterday = [
        ScanResult.fake(localIdentifier: 'a', category: NsfwCategory.safe),
        ScanResult.fake(localIdentifier: 'b', category: NsfwCategory.safe),
      ];
      final today = [
        ScanResult.fake(localIdentifier: 'a', category: NsfwCategory.nudity),
        ScanResult.fake(localIdentifier: 'b', category: NsfwCategory.safe),
        ScanResult.fake(localIdentifier: 'c', category: NsfwCategory.safe),
      ];

      expect(today.newSince(yesterday).map((r) => r.item.localIdentifier),
          ['c']);
      expect(today.changedFrom(yesterday).map((r) => r.item.localIdentifier),
          containsAll(['a', 'c']));
    });

    test('nsfwOnly / failedOnly filters', () {
      final list = [
        ScanResult.fake(localIdentifier: '1', category: NsfwCategory.safe),
        ScanResult.fake(
          localIdentifier: '2',
          category: NsfwCategory.explicitNudity,
          confidence: 0.95,
        ),
        ScanResult.failed(
          localIdentifier: '3',
          errorMessage: 'x',
        ),
      ];
      expect(list.nsfwOnly.length, 1);
      expect(list.nsfwOnly.first.item.localIdentifier, '2');
      expect(list.failedOnly.length, 1);
      expect(list.failedOnly.first.item.localIdentifier, '3');
    });
  });
}
