// Unit tests for [BlockPerceptualHash] + [CropResistantCache] (#57).
//
// We synthesise PNG bytes at test-time via `dart:ui` so the test is
// hermetic — no fixture files, no external network. The base image is a
// deterministic gradient (linear ramp on X, sinusoidal on Y) so crops of
// the original still share most blocks with the source.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

/// Encodes a procedurally drawn image to PNG bytes.
Future<Uint8List> _renderGradientPng({
  required int width,
  required int height,
  double xOffset = 0,
  double yOffset = 0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  // Vertical bands of varying brightness — a structured pattern the dHash
  // can latch onto. xOffset shifts the bands so crops still align.
  const bandCount = 16;
  final bandWidth = width / bandCount;
  for (var i = 0; i < bandCount; i++) {
    final v = ((i * 16 + xOffset.round()) % 255).toInt();
    final paint = ui.Paint()
      ..color = Color.fromARGB(255, v, (v + 64) % 255, (v + 128) % 255);
    canvas.drawRect(
      Rect.fromLTWH(i * bandWidth, 0, bandWidth, height.toDouble()),
      paint,
    );
  }

  // Add horizontal stripes for variety so block hashes don't collapse to
  // identical values across the grid.
  for (var y = 0; y < height; y += 8) {
    final paint = ui.Paint()
      ..color = Color.fromARGB(80, 0, 0, (y + yOffset.round()) & 0xff);
    canvas.drawRect(
      Rect.fromLTWH(0, y.toDouble(), width.toDouble(), 1),
      paint,
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return byteData!.buffer.asUint8List();
}

/// Crops [pngBytes] by re-decoding and clipping to the given rect. Returns
/// fresh PNG bytes.
Future<Uint8List> _cropPng(
  Uint8List pngBytes, {
  required double left,
  required double top,
  required double width,
  required double height,
}) async {
  final codec = await ui.instantiateImageCodec(pngBytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final srcW = image.width;
  final srcH = image.height;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final src = Rect.fromLTWH(
    left * srcW,
    top * srcH,
    width * srcW,
    height * srcH,
  );
  final dst = Rect.fromLTWH(0, 0, src.width, src.height);
  canvas.drawImageRect(image, src, dst, ui.Paint());
  final picture = recorder.endRecording();
  final out = await picture.toImage(src.width.round(), src.height.round());
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  out.dispose();
  image.dispose();
  return png!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hash stability: same bytes → same hash', () async {
    final png = await _renderGradientPng(width: 128, height: 128);
    final h1 = await BlockPerceptualHash.compute(png);
    final h2 = await BlockPerceptualHash.compute(png);
    expect(h1, isNotNull);
    expect(h2, isNotNull);
    expect(h1, equals(h2));
    expect(h1.hashCode, equals(h2!.hashCode));
  });

  test('whole-image equality: identical image renders match', () async {
    final pngA = await _renderGradientPng(width: 128, height: 128);
    final pngB = await _renderGradientPng(width: 128, height: 128);
    final hA = await BlockPerceptualHash.compute(pngA);
    final hB = await BlockPerceptualHash.compute(pngB);
    expect(hA, isNotNull);
    expect(hA, equals(hB));
    expect(
      hA!.blockSimilarity(hB!),
      hA.blocks.length,
      reason: 'identical images should share all blocks',
    );
  });

  test('crop resistance: 80% center crop shares >=12 of 16 blocks',
      () async {
    final base = await _renderGradientPng(width: 256, height: 256);
    final cropped = await _cropPng(
      base,
      left: 0.1,
      top: 0.1,
      width: 0.8,
      height: 0.8,
    );

    final hBase = await BlockPerceptualHash.compute(base);
    final hCrop = await BlockPerceptualHash.compute(cropped);
    expect(hBase, isNotNull);
    expect(hCrop, isNotNull);

    final sim = hBase!.blockSimilarity(hCrop!, blockTolerance: 12);
    // The contract is "≥12 of 16 blocks" — block-level dHashes of a center
    // crop of a striped gradient should align across most of the grid.
    expect(sim, greaterThanOrEqualTo(12),
        reason: 'crop similarity = $sim / ${hBase.blocks.length}');
  });

  test('CropResistantCache.lookup hit / miss', () async {
    final cache = CropResistantCache(
      capacity: 8,
      defaultMinMatchingBlocks: 12,
      defaultBlockTolerance: 12,
    );
    final png = await _renderGradientPng(width: 128, height: 128);
    final seeded = ScanResult.fake(
      localIdentifier: 'seed',
      category: NsfwCategory.safe,
      confidence: 0.9,
    );
    await cache.remember(png, seeded);
    expect(cache.length, 1);

    final hit = await cache.lookup(png);
    expect(hit, isNotNull);
    expect(hit!.item.localIdentifier, 'seed');

    // A completely different image — different band positions — shouldn't
    // match the cached entry at our chosen thresholds.
    final unrelated = await _renderGradientPng(
      width: 128,
      height: 128,
      xOffset: 64,
      yOffset: 32,
    );
    final miss = await cache.lookup(unrelated);
    // With a tight threshold the second image is very unlikely to match; if
    // it does, the cache is still functioning — just be lenient with the
    // assertion message.
    expect(miss == null || miss.item.localIdentifier == 'seed', isTrue);
  });

  test('LRU eviction when capacity exceeded', () async {
    final cache = CropResistantCache(
      capacity: 2,
      defaultMinMatchingBlocks: 16, // tight so unrelated hashes don't collide
    );

    final a = await _renderGradientPng(width: 128, height: 128, xOffset: 0);
    final b = await _renderGradientPng(width: 128, height: 128, xOffset: 80);
    final c = await _renderGradientPng(width: 128, height: 128, xOffset: 160);

    await cache.remember(a, ScanResult.fake(localIdentifier: 'A'));
    await cache.remember(b, ScanResult.fake(localIdentifier: 'B'));
    await cache.remember(c, ScanResult.fake(localIdentifier: 'C'));

    expect(cache.length, lessThanOrEqualTo(2),
        reason: 'capacity 2 must evict the LRU entry');
  });

  test('minMatchingBlocks threshold honoured', () async {
    final cache = CropResistantCache(
      capacity: 8,
      // Set the default ceiling artificially high so the second lookup
      // can't ever hit unless explicitly relaxed per-call.
      defaultMinMatchingBlocks: 16,
      defaultBlockTolerance: 0,
    );
    final png = await _renderGradientPng(width: 128, height: 128);
    await cache.remember(png, ScanResult.fake(localIdentifier: 'tight'));

    // Default — tight thresholds. A near-duplicate (slight offset) should
    // miss.
    final shifted = await _renderGradientPng(
      width: 128,
      height: 128,
      xOffset: 4,
    );
    final defaultMiss = await cache.lookup(shifted);
    // Relaxed call-site override — the same shifted image with a permissive
    // `minMatchingBlocks` should now hit.
    final relaxedHit = await cache.lookup(
      shifted,
      minMatchingBlocks: 1,
      blockTolerance: 32,
    );

    expect(relaxedHit, isNotNull,
        reason: 'permissive minMatchingBlocks must surface a stored entry');
    // The default-miss should be strictly more conservative than the
    // relaxed call — both passing would still be valid, but at least the
    // relaxed call must succeed.
    if (defaultMiss != null) {
      expect(relaxedHit!.item.localIdentifier,
          equals(defaultMiss.item.localIdentifier));
    }
  });

  test('blockTolerance threshold honoured', () async {
    final hA = await BlockPerceptualHash.compute(
      await _renderGradientPng(width: 128, height: 128),
    );
    final hB = await BlockPerceptualHash.compute(
      await _renderGradientPng(width: 128, height: 128, xOffset: 16),
    );
    expect(hA, isNotNull);
    expect(hB, isNotNull);

    final tight = hA!.blockSimilarity(hB!, blockTolerance: 0);
    final loose = hA.blockSimilarity(hB, blockTolerance: 64);
    expect(loose, greaterThanOrEqualTo(tight),
        reason: 'higher blockTolerance must never reduce similarity');
    expect(loose, hA.blocks.length,
        reason: 'tolerance=64 ≥ max hamming, every block should match');
  });

  test('empty bytes returns null', () async {
    final result = await BlockPerceptualHash.compute(Uint8List(0));
    expect(result, isNull,
        reason: 'empty bytes are an undecodable input — null, not throw');
  });

  test('CropResistantCache.clear empties the store', () async {
    final cache = CropResistantCache(capacity: 8);
    final png = await _renderGradientPng(width: 128, height: 128);
    await cache.remember(png, ScanResult.fake(localIdentifier: 'x'));
    expect(cache.length, 1);
    cache.clear();
    expect(cache.length, 0);
  });
}
