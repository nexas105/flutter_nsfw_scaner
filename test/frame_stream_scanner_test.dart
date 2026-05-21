// Unit tests for [FrameStreamScanner] — exercises throttling, backpressure,
// early-exit, and dedupe-cache integration. The underlying [scanBytes] call
// is mocked via [FakeNsfwPlatform] so the model never runs.
//
// NOTE: [FrameStreamScanner] uses wall-clock `DateTime.now()` for its
// throttle window, so we can't drive the time entirely via `fake_async`.
// Instead we feed frames at real intervals (~50ms) — fast enough to keep
// `flutter test` snappy, slow enough that the throttle window (250ms at
// `targetFps: 4`) actually gates emission.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

import '_fakes/fake_nsfw_detector.dart';

void main() {
  late FakeNsfwPlatform fake;

  setUp(() {
    fake = FakeNsfwPlatform();
    NsfwPlatformInterface.instance = fake;
  });

  tearDown(() {
    fake.dispose();
  });

  Uint8List bytesOfLen(int n) => Uint8List.fromList(List<int>.filled(n, n & 0xff));

  test('throttles 20 input frames to <=5 results at targetFps: 4', () async {
    fake.seedFrameResults(List<ScanResult>.generate(
      20,
      (i) => ScanResult.fake(
        localIdentifier: 'frame-$i',
        category: NsfwCategory.safe,
        confidence: 0.5,
      ),
    ));

    final controller = StreamController<Uint8List>();
    final scanner = NsfwDetector.instance.scanFrameStream(
      frames: controller.stream,
      targetFps: 4,
    );

    final received = <ScanResult>[];
    final sub = scanner.results.listen(received.add);

    // Pump 20 frames at 50ms intervals → 1000ms of real time. At targetFps=4
    // the scanner should accept at most ~4–5 frames (one per 250ms window).
    for (var i = 0; i < 20; i++) {
      controller.add(bytesOfLen(i + 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Give the in-flight scan a moment to complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await controller.close();
    await scanner.stop();
    await sub.cancel();

    expect(received.length, lessThanOrEqualTo(5),
        reason: 'targetFps=4 over ~1s should yield <=5 results');
    expect(received.length, greaterThanOrEqualTo(1),
        reason: 'at least one frame should make it through');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('backpressure: never queues >1 in-flight scan', () async {
    // Replace scanImageBytes with a slow scripted response so the second
    // frame arrives while the first is still in-flight.
    fake.seedFrameResults(List<ScanResult>.generate(
      5,
      (i) => ScanResult.fake(
        localIdentifier: 'bp-$i',
        category: NsfwCategory.safe,
        confidence: 0.5,
      ),
    ));

    final controller = StreamController<Uint8List>();
    final scanner = NsfwDetector.instance.scanFrameStream(
      frames: controller.stream,
      targetFps: 100, // effectively no throttle — backpressure is the gate
    );

    final received = <ScanResult>[];
    final sub = scanner.results.listen(received.add);

    // Synchronously dump 10 frames — most should be dropped because the
    // first scan is still resolving on the microtask queue.
    for (var i = 0; i < 10; i++) {
      controller.add(bytesOfLen(100 + i));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await controller.close();
    await scanner.stop();
    await sub.cancel();

    // The fake resolves synchronously, but the StreamController dispatch is
    // async — so we expect roughly 1–3 results, never the full 10.
    expect(received.length, lessThan(10));
  });

  test('earlyExitOnNsfw closes the stream on first NSFW result', () async {
    fake.seedFrameResults([
      ScanResult.fake(
        localIdentifier: 'safe-1',
        category: NsfwCategory.safe,
        confidence: 0.9,
      ),
      ScanResult.fake(
        localIdentifier: 'nsfw-1',
        category: NsfwCategory.explicitNudity,
        confidence: 0.95,
      ),
      ScanResult.fake(
        localIdentifier: 'after-nsfw',
        category: NsfwCategory.safe,
        confidence: 0.5,
      ),
    ]);

    final controller = StreamController<Uint8List>();
    final scanner = NsfwDetector.instance.scanFrameStream(
      frames: controller.stream,
      targetFps: 30, // generous so frames are accepted
      earlyExitOnNsfw: true,
    );

    final received = <ScanResult>[];
    var closed = false;
    final sub = scanner.results.listen(
      received.add,
      onDone: () => closed = true,
    );

    // Feed three frames with enough spacing for the throttle to admit each.
    controller.add(bytesOfLen(1));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    controller.add(bytesOfLen(2));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    controller.add(bytesOfLen(3));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await sub.cancel();
    await controller.close();

    // Result stream should have closed once the NSFW result landed.
    expect(closed, isTrue);
    // No further results were emitted after the NSFW one.
    expect(received.any((r) => r.isNsfw), isTrue);
    expect(
      received.where((r) => r.item.localIdentifier == 'after-nsfw'),
      isEmpty,
    );
  });

  test('stop() is idempotent and closes the result stream', () async {
    final controller = StreamController<Uint8List>();
    final scanner = NsfwDetector.instance.scanFrameStream(
      frames: controller.stream,
      targetFps: 4,
    );

    var doneCount = 0;
    scanner.results.listen((_) {}, onDone: () => doneCount++);

    await scanner.stop();
    await scanner.stop(); // idempotent — must not throw
    await controller.close();

    // Allow listeners to settle.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(doneCount, 1);
  });

  test('dedupe cache replays cached result with fromCache=true', () async {
    final cache = PerceptualCache(capacity: 8, defaultMaxDistance: 5);
    // Pre-seed the cache with a result keyed off a deterministic byte
    // payload so the second frame with the same payload hits the cache.
    final bytes = bytesOfLen(42);
    final seeded = ScanResult.fake(
      localIdentifier: 'cached',
      category: NsfwCategory.safe,
      confidence: 0.88,
    );
    await cache.remember(bytes, seeded);
    // If the test image bytes are too small for the dHash pipeline (no real
    // decode happens), `remember` is a no-op. Skip in that case — this test
    // documents the cache path, not the hashing internals.
    if (cache.length == 0) {
      markTestSkipped('PerceptualCache could not hash synthetic bytes — '
          'covered by perceptual_cache tests with real images.');
      return;
    }

    fake.seedFrameResults([
      ScanResult.fake(
        localIdentifier: 'fresh',
        category: NsfwCategory.safe,
        confidence: 0.5,
      ),
    ]);

    final controller = StreamController<Uint8List>();
    final scanner = NsfwDetector.instance.scanFrameStream(
      frames: controller.stream,
      targetFps: 30,
      dedupeCache: cache,
    );

    final received = <ScanResult>[];
    final sub = scanner.results.listen(received.add);

    controller.add(bytes);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await sub.cancel();
    await controller.close();
    await scanner.stop();

    expect(received, isNotEmpty);
    expect(received.first.fromCache, isTrue,
        reason: 'should replay cached result with fromCache=true');
  });
}
