import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'scan_result.dart';

/// 64-bit perceptual hash of an image. Computed from a 9x8 grayscale
/// downsample using the [difference-hash (dHash)][dHash] algorithm — each of
/// the 64 bits encodes whether pixel `(x, y)` is brighter than `(x+1, y)`.
///
/// Two images that look similar to a human are very likely to have a low
/// Hamming distance (3–10 bits). Two unrelated images will sit closer to 32
/// (random) bits apart. Compare with [hammingDistance].
///
/// [dHash]: https://www.hackerfactor.com/blog/index.php?/archives/529-Kind-of-Like-That.html
@immutable
class PerceptualHash {
  /// 16-char lowercase hex string (64 bits).
  final String hex;

  const PerceptualHash(this.hex);

  /// JSON-friendly serialisation — just the hex string. Symmetric with
  /// [PerceptualHash.fromJson]. Useful for persisting hashes alongside
  /// `MediaItem.localIdentifier` for incremental dedup across launches.
  String toJson() => hex;

  /// Restores a hash previously produced by [toJson] (or any raw 16-char
  /// hex string). Throws [FormatException] when [json] isn't a valid
  /// 16-character lowercase hex string.
  factory PerceptualHash.fromJson(String json) {
    if (json.length != 16 ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(json)) {
      throw FormatException('PerceptualHash expects a 16-char hex string', json);
    }
    return PerceptualHash(json);
  }

  /// Alias for [compute]. Mirrors `BodyPartDetection.fromBytes`-style naming
  /// for callers used to factories on value types.
  static Future<PerceptualHash?> fromBytes(Uint8List bytes) => compute(bytes);

  /// Computes the dHash for [bytes] (any format Flutter's image codecs can
  /// decode — JPEG, PNG, WebP). Returns `null` if decoding fails.
  ///
  /// This decodes the full image once, so prefer caching the result when
  /// you'll compare an image against the cache multiple times.
  static Future<PerceptualHash?> compute(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 9,
        targetHeight: 8,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List();

      // 9x8 → 64 dHash bits (compare each pixel to the one on its right).
      var bits = BigInt.zero;
      var bit = 0;
      for (var y = 0; y < 8; y++) {
        // Each row has 9 pixels of 4 bytes (RGBA).
        final rowOffset = y * 9 * 4;
        for (var x = 0; x < 8; x++) {
          final i = rowOffset + x * 4;
          final j = rowOffset + (x + 1) * 4;
          // Rec. 601 luma — keeps things simple and dependency-free.
          final l1 = 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
          final l2 = 0.299 * rgba[j] + 0.587 * rgba[j + 1] + 0.114 * rgba[j + 2];
          if (l1 > l2) {
            bits |= BigInt.one << bit;
          }
          bit++;
        }
      }

      final hex = bits.toRadixString(16).padLeft(16, '0');
      return PerceptualHash(hex);
    } catch (_) {
      return null;
    }
  }

  /// Hamming distance between this hash and [other] — number of bits that
  /// differ. Range `[0, 64]`. Lower = more similar.
  int hammingDistance(PerceptualHash other) {
    final a = BigInt.parse(hex, radix: 16);
    final b = BigInt.parse(other.hex, radix: 16);
    var xor = a ^ b;
    var count = 0;
    while (xor > BigInt.zero) {
      if ((xor & BigInt.one) != BigInt.zero) count++;
      xor = xor >> 1;
    }
    return count;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PerceptualHash && hex == other.hex);

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => 'PerceptualHash($hex)';
}

/// LRU cache mapping [PerceptualHash]es to [ScanResult]s. Useful as a
/// pre-check before paying the cost of `scanBytes` — if you've already
/// classified a near-duplicate, you can reuse the previous label.
///
/// The cache is opt-in and NOT wired into `NsfwDetector` automatically.
/// A typical integration:
///
/// ```dart
/// final cache = NsfwDetector.instance.perceptualCache;
/// final cached = await cache.lookup(bytes);
/// if (cached != null) return cached;
/// final result = await NsfwDetector.instance.scanBytes(bytes);
/// await cache.remember(bytes, result);
/// ```
///
/// Capacity defaults to 256 entries — bump it for high-throughput batch
/// pipelines, drop it for memory-constrained surfaces. All state lives in
/// memory; nothing is persisted between launches.
class PerceptualCache {
  PerceptualCache({this.capacity = 256, this.defaultMaxDistance = 5})
      : assert(capacity > 0, 'capacity must be positive'),
        assert(
          defaultMaxDistance >= 0 && defaultMaxDistance <= 64,
          'defaultMaxDistance must be in [0, 64]',
        );

  /// Maximum entries retained before LRU eviction.
  final int capacity;

  /// Default Hamming-distance window for [lookup].
  final int defaultMaxDistance;

  // Ordered by insertion/access — last entry is MRU.
  final LinkedHashMap<PerceptualHash, ScanResult> _entries =
      LinkedHashMap<PerceptualHash, ScanResult>();

  /// Number of entries currently in the cache.
  int get length => _entries.length;

  /// Looks up [bytes] in the cache. Returns the closest [ScanResult] whose
  /// stored hash is within [maxDistance] bits of the query, or `null` if no
  /// entry is close enough (or the bytes could not be hashed).
  Future<ScanResult?> lookup(
    Uint8List bytes, {
    int? maxDistance,
  }) async {
    final hash = await PerceptualHash.compute(bytes);
    if (hash == null) return null;
    return lookupByHash(hash, maxDistance: maxDistance);
  }

  /// Variant of [lookup] for callers that already computed the hash.
  ScanResult? lookupByHash(PerceptualHash hash, {int? maxDistance}) {
    if (_entries.isEmpty) return null;
    final limit = maxDistance ?? defaultMaxDistance;

    // Exact-hit fast path.
    final exact = _entries[hash];
    if (exact != null) {
      _touch(hash);
      return exact;
    }

    PerceptualHash? bestKey;
    ScanResult? best;
    int bestDistance = limit + 1;
    for (final entry in _entries.entries) {
      final d = hash.hammingDistance(entry.key);
      if (d < bestDistance) {
        bestDistance = d;
        best = entry.value;
        bestKey = entry.key;
        if (d == 0) break;
      }
    }
    if (best == null || bestDistance > limit) return null;
    if (bestKey != null) _touch(bestKey);
    return best;
  }

  /// Stores [result] in the cache keyed by the perceptual hash of [bytes].
  /// Silently no-ops if hashing fails.
  Future<void> remember(Uint8List bytes, ScanResult result) async {
    final hash = await PerceptualHash.compute(bytes);
    if (hash == null) return;
    rememberByHash(hash, result);
  }

  /// Variant of [remember] for callers that already computed the hash.
  void rememberByHash(PerceptualHash hash, ScanResult result) {
    // Touch / insert.
    _entries.remove(hash);
    _entries[hash] = result;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Drops every cached entry.
  void clear() => _entries.clear();

  void _touch(PerceptualHash hash) {
    final v = _entries.remove(hash);
    if (v != null) _entries[hash] = v;
  }
}

/// Crop-resistant perceptual hash. Divides the image into an N×N grid (default
/// 4×4 = 16 blocks) and computes an 8×8 dHash per block. Two images that
/// share content survive cropping that removes up to (`N²` - [minMatchingBlocks])
/// blocks of either side — at the default 6-of-16 threshold this tolerates
/// losing roughly 60% of the original frame.
///
/// Use via [CropResistantCache] for forwarded-image moderation; the lookup
/// cost is roughly 16× a single [PerceptualHash] comparison, so prefer
/// [PerceptualCache] for hot paths where crops aren't expected.
@immutable
class BlockPerceptualHash {
  /// Default grid size. Each axis is divided into [defaultGridSize] strips,
  /// producing `defaultGridSize * defaultGridSize` blocks.
  static const int defaultGridSize = 4;

  /// One 64-bit dHash per block. Length = `gridSize * gridSize`.
  final List<int> blocks;

  /// Grid edge length — `sqrt(blocks.length)`.
  final int gridSize;

  const BlockPerceptualHash(this.blocks, {this.gridSize = defaultGridSize});

  /// Computes a block-level dHash for [bytes]. The image is downscaled to a
  /// single `(gridSize * 9) × (gridSize * 8)` buffer so all blocks come from
  /// the same decode (one codec round-trip total).
  ///
  /// Returns `null` if decoding fails.
  static Future<BlockPerceptualHash?> compute(
    Uint8List bytes, {
    int gridSize = defaultGridSize,
  }) async {
    assert(gridSize > 0, 'gridSize must be positive');
    try {
      // Each block needs 9×8 pixels for dHash; we decode the entire grid in
      // one shot to avoid `gridSize²` separate decode passes.
      final targetWidth = gridSize * 9;
      final targetHeight = gridSize * 8;
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List();

      final blocks = List<int>.filled(gridSize * gridSize, 0);
      for (var by = 0; by < gridSize; by++) {
        for (var bx = 0; bx < gridSize; bx++) {
          var hash = 0;
          var bit = 0;
          for (var y = 0; y < 8; y++) {
            final imgY = by * 8 + y;
            final rowOffset = imgY * targetWidth * 4;
            final blockColStart = bx * 9;
            for (var x = 0; x < 8; x++) {
              final i = rowOffset + (blockColStart + x) * 4;
              final j = rowOffset + (blockColStart + x + 1) * 4;
              final l1 = 0.299 * rgba[i] +
                  0.587 * rgba[i + 1] +
                  0.114 * rgba[i + 2];
              final l2 = 0.299 * rgba[j] +
                  0.587 * rgba[j + 1] +
                  0.114 * rgba[j + 2];
              if (l1 > l2) hash |= 1 << bit;
              bit++;
            }
          }
          blocks[by * gridSize + bx] = hash;
        }
      }
      return BlockPerceptualHash(
        List<int>.unmodifiable(blocks),
        gridSize: gridSize,
      );
    } catch (_) {
      return null;
    }
  }

  /// Returns the count of blocks in `this` that match any block in [other]
  /// within [blockTolerance] bits. Symmetric — blocks may align at any
  /// position, so cropping that shifts content sideways still scores.
  ///
  /// Range `[0, blocks.length]`. A score ≥ `minMatchingBlocks` is the
  /// signal that the two images share content.
  int blockSimilarity(BlockPerceptualHash other, {int blockTolerance = 8}) {
    if (blocks.isEmpty || other.blocks.isEmpty) return 0;
    var matches = 0;
    for (final a in blocks) {
      for (final b in other.blocks) {
        if (_hammingInt64(a, b) <= blockTolerance) {
          matches++;
          break;
        }
      }
    }
    return matches;
  }

  /// Convenience: returns true iff [blockSimilarity] meets
  /// [minMatchingBlocks].
  bool matches(
    BlockPerceptualHash other, {
    int minMatchingBlocks = 6,
    int blockTolerance = 8,
  }) =>
      blockSimilarity(other, blockTolerance: blockTolerance) >=
      minMatchingBlocks;

  static int _hammingInt64(int a, int b) {
    var x = a ^ b;
    var count = 0;
    while (x != 0) {
      count += x & 1;
      x = (x >> 1) & 0x7FFFFFFFFFFFFFFF; // keep it unsigned-ish for safety
    }
    return count;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BlockPerceptualHash) return false;
    if (other.blocks.length != blocks.length) return false;
    for (var i = 0; i < blocks.length; i++) {
      if (other.blocks[i] != blocks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(blocks);

  @override
  String toString() =>
      'BlockPerceptualHash(${gridSize}x$gridSize, ${blocks.length} blocks)';
}

/// LRU cache keyed by [BlockPerceptualHash]. Same shape as [PerceptualCache]
/// but resilient to crops — ideal for forwarded-image moderation where the
/// same content reappears with different framing.
///
/// **Trade-off:** lookups are O(`n × gridSize²`) where `n` is the cache
/// size — roughly 16× slower than [PerceptualCache] at default settings.
/// Use [PerceptualCache] when you control framing; reach for
/// [CropResistantCache] when content arrives from social-sharing pipelines.
///
/// ```dart
/// final cache = NsfwDetector.instance.cropResistantCache;
/// final cached = await cache.lookup(bytes);
/// if (cached != null) return cached;
/// final result = await NsfwDetector.instance.scanBytes(bytes);
/// await cache.remember(bytes, result);
/// ```
class CropResistantCache {
  CropResistantCache({
    this.capacity = 256,
    this.gridSize = BlockPerceptualHash.defaultGridSize,
    this.defaultMinMatchingBlocks = 6,
    this.defaultBlockTolerance = 8,
  })  : assert(capacity > 0, 'capacity must be positive'),
        assert(gridSize > 0, 'gridSize must be positive'),
        assert(
          defaultMinMatchingBlocks > 0 &&
              defaultMinMatchingBlocks <= gridSize * gridSize,
          'defaultMinMatchingBlocks must be in (0, gridSize * gridSize]',
        ),
        assert(
          defaultBlockTolerance >= 0 && defaultBlockTolerance <= 64,
          'defaultBlockTolerance must be in [0, 64]',
        );

  /// Maximum entries retained before LRU eviction.
  final int capacity;

  /// Grid size used when hashing inputs via [lookup] / [remember].
  final int gridSize;

  /// Default minimum block match count required for [lookup] to return a hit.
  final int defaultMinMatchingBlocks;

  /// Default per-block Hamming-distance tolerance.
  final int defaultBlockTolerance;

  final LinkedHashMap<BlockPerceptualHash, ScanResult> _entries =
      LinkedHashMap<BlockPerceptualHash, ScanResult>();

  /// Number of entries currently in the cache.
  int get length => _entries.length;

  /// Looks up [bytes]. Returns the first stored result whose hash matches
  /// at least [minMatchingBlocks] blocks within [blockTolerance] bits —
  /// promoted to MRU on hit. Returns `null` on miss or hash failure.
  Future<ScanResult?> lookup(
    Uint8List bytes, {
    int? minMatchingBlocks,
    int? blockTolerance,
  }) async {
    final hash = await BlockPerceptualHash.compute(bytes, gridSize: gridSize);
    if (hash == null) return null;
    return lookupByHash(
      hash,
      minMatchingBlocks: minMatchingBlocks,
      blockTolerance: blockTolerance,
    );
  }

  /// Variant of [lookup] for callers that already computed the hash.
  ScanResult? lookupByHash(
    BlockPerceptualHash hash, {
    int? minMatchingBlocks,
    int? blockTolerance,
  }) {
    if (_entries.isEmpty) return null;
    final minMatch = minMatchingBlocks ?? defaultMinMatchingBlocks;
    final tol = blockTolerance ?? defaultBlockTolerance;

    // Iterate insertion order; first hit wins (and gets promoted).
    for (final entry in _entries.entries) {
      if (hash.matches(
        entry.key,
        minMatchingBlocks: minMatch,
        blockTolerance: tol,
      )) {
        _touch(entry.key);
        return entry.value;
      }
    }
    return null;
  }

  /// Stores [result] keyed by the block-hash of [bytes]. No-op on hash
  /// failure.
  Future<void> remember(Uint8List bytes, ScanResult result) async {
    final hash = await BlockPerceptualHash.compute(bytes, gridSize: gridSize);
    if (hash == null) return;
    rememberByHash(hash, result);
  }

  /// Variant of [remember] for callers that already computed the hash.
  void rememberByHash(BlockPerceptualHash hash, ScanResult result) {
    _entries.remove(hash);
    _entries[hash] = result;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Drops every cached entry.
  void clear() => _entries.clear();

  void _touch(BlockPerceptualHash hash) {
    final v = _entries.remove(hash);
    if (v != null) _entries[hash] = v;
  }
}
