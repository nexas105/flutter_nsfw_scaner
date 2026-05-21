import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

import '_fakes/fake_nsfw_detector.dart';

void main() {
  group('ScanDecision wire format', () {
    test('round-trips through wireValue / fromWire', () {
      for (final d in ScanDecision.values) {
        expect(ScanDecision.fromWire(d.wireValue), d);
      }
      expect(ScanDecision.fromWire(null), isNull);
      expect(ScanDecision.fromWire('bogus'), isNull);
    });
  });

  group('ScanResult.userDecision', () {
    test('allow overrides classifier NSFW signal', () {
      final r = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.99,
      ).withUserDecision(ScanDecision.allow);
      expect(r.isNsfw, isFalse);
      expect(r.userDecision, ScanDecision.allow);
    });

    test('block overrides classifier safe signal', () {
      final r = ScanResult.fake(
        category: NsfwCategory.safe,
        confidence: 0.99,
      ).withUserDecision(ScanDecision.block);
      expect(r.isNsfw, isTrue);
    });

    test('reset clears the override', () {
      final base = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.99,
      ).withUserDecision(ScanDecision.allow);
      final cleared = base.withUserDecision(ScanDecision.reset);
      expect(cleared.userDecision, isNull);
      expect(cleared.isNsfw, isTrue, reason: 'falls back to classifier');
    });

    test('JSON round-trip preserves the decision', () {
      final base = ScanResult.fake(
        category: NsfwCategory.nudity,
        confidence: 0.8,
      ).withUserDecision(ScanDecision.allow);
      final restored = ScanResult.fromJson(base.toJson());
      expect(restored.userDecision, ScanDecision.allow);
      expect(restored.isNsfw, isFalse);
    });
  });

  group('InMemoryDecisionStore', () {
    test('mark/get/getAll/clear round-trip', () async {
      final store = InMemoryDecisionStore();
      addTearDown(store.dispose);

      await store.mark('a', ScanDecision.allow);
      await store.mark('b', ScanDecision.block);
      expect(await store.get('a'), ScanDecision.allow);
      expect(await store.get('missing'), isNull);
      expect(await store.getAll(), {
        'a': ScanDecision.allow,
        'b': ScanDecision.block,
      });

      await store.mark('a', ScanDecision.reset);
      expect(await store.get('a'), isNull);

      await store.clear();
      expect(await store.getAll(), isEmpty);
    });

    test('changes stream emits per mark', () async {
      final store = InMemoryDecisionStore();
      addTearDown(store.dispose);

      final received = <DecisionChange>[];
      final sub = store.changes.listen(received.add);
      addTearDown(sub.cancel);

      await store.mark('x', ScanDecision.allow);
      await store.mark('y', ScanDecision.block);
      await store.mark('x', ScanDecision.reset);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        const DecisionChange('x', ScanDecision.allow),
        const DecisionChange('y', ScanDecision.block),
        const DecisionChange('x', ScanDecision.reset),
      ]);
    });
  });

  group('SharedPreferencesDecisionStore', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('survives a fresh instance over the same SharedPreferences', () async {
      final first = SharedPreferencesDecisionStore();
      await first.mark('img-1', ScanDecision.allow);
      await first.mark('img-2', ScanDecision.block);
      await first.dispose();

      final second = SharedPreferencesDecisionStore();
      addTearDown(second.dispose);
      expect(await second.get('img-1'), ScanDecision.allow);
      expect(await second.get('img-2'), ScanDecision.block);
    });

    test('encodes pipes / newlines in localIds safely', () async {
      final first = SharedPreferencesDecisionStore();
      await first.mark('a|b\\n\nc', ScanDecision.allow);
      await first.dispose();

      final second = SharedPreferencesDecisionStore();
      addTearDown(second.dispose);
      expect(await second.get('a|b\\n\nc'), ScanDecision.allow);
    });
  });

  group('NsfwDetector integration', () {
    late FakeNsfwPlatform fake;

    setUp(() {
      fake = FakeNsfwPlatform();
      NsfwPlatformInterface.instance = fake;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    tearDown(() async {
      await NsfwDetector.instance.useDecisionStore(InMemoryDecisionStore());
      fake.dispose();
    });

    test('one-shot scanAsset attaches userDecision from store', () async {
      fake.results['asset-7'] = ScanResult.fake(
        localIdentifier: 'asset-7',
        category: NsfwCategory.explicitNudity,
        confidence: 0.95,
      );

      // Prime the store and let the async snapshot land before scanning.
      await NsfwDetector.instance.decisions
          .mark('asset-7', ScanDecision.allow);
      await Future<void>.delayed(Duration.zero);

      final result = await NsfwDetector.instance.scanAsset('asset-7');
      expect(result.userDecision, ScanDecision.allow);
      expect(result.isNsfw, isFalse,
          reason: 'allow override beats the classifier');
    });

    test('scanBytes leaves userDecision null when no localId is known',
        () async {
      fake.seedFrameResults([ScanResult.fake()]);
      final result =
          await NsfwDetector.instance.scanBytes(Uint8List.fromList([1, 2]));
      expect(result.userDecision, isNull);
    });

    test('useDecisionStore swaps backing store and disposes the old one',
        () async {
      final swap = InMemoryDecisionStore();
      await NsfwDetector.instance.useDecisionStore(swap);
      expect(identical(NsfwDetector.instance.decisions, swap), isTrue);
    });
  });
}
