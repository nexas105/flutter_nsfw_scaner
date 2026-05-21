import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scan_decision.dart';

/// Persistent map of moderator overrides keyed by an asset's
/// `localIdentifier`.
///
/// Decisions outlive a scan and are surfaced on freshly-fetched
/// [ScanResult]s via `ScanResult.userDecision`. Apps replace the default
/// in-memory store via `NsfwDetector.useDecisionStore(...)` with one of:
///
///  * [InMemoryDecisionStore] — default; lost on cold start.
///  * [SharedPreferencesDecisionStore] — backed by the bundled
///    `shared_preferences` plugin; survives process restarts.
///  * A custom subclass — for `sqflite`, `isar`, `hive`, or any other
///    storage layer.
abstract class DecisionStore {
  /// Records [decision] for [localId]. `ScanDecision.reset` removes any
  /// existing entry; otherwise the entry is overwritten.
  Future<void> mark(String localId, ScanDecision decision);

  /// Returns the current decision for [localId], or `null` when none is set.
  Future<ScanDecision?> get(String localId);

  /// Returns a snapshot of every persisted decision.
  Future<Map<String, ScanDecision>> getAll();

  /// Stream of `(localId, decision)` change events. Subscribers receive an
  /// event for every `mark` (including resets, which emit
  /// `ScanDecision.reset`). The stream completes when the store is
  /// disposed.
  Stream<DecisionChange> get changes;

  /// Removes every persisted decision.
  Future<void> clear();

  /// Releases any underlying resources. Subsequent calls become no-ops.
  Future<void> dispose() async {}
}

/// `(localId, decision)` change notification emitted by
/// [DecisionStore.changes].
@immutable
class DecisionChange {
  final String localId;
  final ScanDecision decision;

  const DecisionChange(this.localId, this.decision);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DecisionChange &&
          localId == other.localId &&
          decision == other.decision;

  @override
  int get hashCode => Object.hash(localId, decision);

  @override
  String toString() => 'DecisionChange($localId → ${decision.name})';
}

/// Volatile in-memory [DecisionStore]. Lost on process restart — good
/// enough for tests and the small-library cases where the host app
/// already persists its own decision state out of band.
class InMemoryDecisionStore implements DecisionStore {
  final Map<String, ScanDecision> _entries;
  final StreamController<DecisionChange> _controller =
      StreamController<DecisionChange>.broadcast();
  bool _disposed = false;

  InMemoryDecisionStore({Map<String, ScanDecision>? seed})
      : _entries = {...?seed};

  @override
  Future<void> mark(String localId, ScanDecision decision) async {
    if (_disposed) return;
    if (decision == ScanDecision.reset) {
      _entries.remove(localId);
    } else {
      _entries[localId] = decision;
    }
    if (!_controller.isClosed) {
      _controller.add(DecisionChange(localId, decision));
    }
  }

  @override
  Future<ScanDecision?> get(String localId) async => _entries[localId];

  @override
  Future<Map<String, ScanDecision>> getAll() async =>
      Map.unmodifiable(_entries);

  @override
  Stream<DecisionChange> get changes => _controller.stream;

  @override
  Future<void> clear() async {
    if (_disposed) return;
    final keys = _entries.keys.toList(growable: false);
    _entries.clear();
    if (!_controller.isClosed) {
      for (final k in keys) {
        _controller.add(DecisionChange(k, ScanDecision.reset));
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _controller.close();
  }
}

/// Persistent [DecisionStore] backed by `shared_preferences`.
///
/// Persists every entry under a single string key (default
/// `nsfw_detect.decisions`) encoded as a `localId|wireValue` pair per
/// line. Suitable for libraries with up to a few thousand overrides; for
/// larger volumes ship a `sqflite` subclass instead.
class SharedPreferencesDecisionStore implements DecisionStore {
  /// Key under which the encoded entries are stored.
  final String storageKey;

  final StreamController<DecisionChange> _controller =
      StreamController<DecisionChange>.broadcast();
  final SharedPreferencesAsync _prefs;
  Map<String, ScanDecision>? _cache;
  bool _disposed = false;
  Future<void>? _loadingFuture;

  SharedPreferencesDecisionStore({
    this.storageKey = 'nsfw_detect.decisions',
    SharedPreferencesAsync? prefs,
  }) : _prefs = prefs ?? SharedPreferencesAsync();

  Future<void> _ensureLoaded() {
    final inFlight = _loadingFuture;
    if (inFlight != null) return inFlight;
    if (_cache != null) return Future.value();
    final fut = () async {
      final raw = await _prefs.getString(storageKey);
      _cache = _decode(raw);
    }();
    _loadingFuture = fut;
    try {
      return fut;
    } finally {
      fut.whenComplete(() {
        if (identical(_loadingFuture, fut)) _loadingFuture = null;
      });
    }
  }

  Future<void> _flush() async {
    final cache = _cache;
    if (cache == null) return;
    if (cache.isEmpty) {
      await _prefs.remove(storageKey);
    } else {
      await _prefs.setString(storageKey, _encode(cache));
    }
  }

  @override
  Future<void> mark(String localId, ScanDecision decision) async {
    if (_disposed) return;
    await _ensureLoaded();
    final cache = _cache!;
    if (decision == ScanDecision.reset) {
      if (cache.remove(localId) == null) {
        // Emit a reset change anyway so subscribers can react idempotently.
      }
    } else {
      cache[localId] = decision;
    }
    await _flush();
    if (!_controller.isClosed) {
      _controller.add(DecisionChange(localId, decision));
    }
  }

  @override
  Future<ScanDecision?> get(String localId) async {
    if (_disposed) return null;
    await _ensureLoaded();
    return _cache![localId];
  }

  @override
  Future<Map<String, ScanDecision>> getAll() async {
    if (_disposed) return const {};
    await _ensureLoaded();
    return Map.unmodifiable(_cache!);
  }

  @override
  Stream<DecisionChange> get changes => _controller.stream;

  @override
  Future<void> clear() async {
    if (_disposed) return;
    await _ensureLoaded();
    final cache = _cache!;
    final keys = cache.keys.toList(growable: false);
    cache.clear();
    await _flush();
    if (!_controller.isClosed) {
      for (final k in keys) {
        _controller.add(DecisionChange(k, ScanDecision.reset));
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _controller.close();
  }

  /// JSON-encodes `{ localId: wireValue }`. `jsonEncode` handles every
  /// escape the storage layer cares about (pipes, newlines, backslashes,
  /// Unicode), so the encoder stays trivially correct.
  static String _encode(Map<String, ScanDecision> entries) {
    final payload = <String, String>{
      for (final entry in entries.entries) entry.key: entry.value.wireValue,
    };
    return jsonEncode(payload);
  }

  static Map<String, ScanDecision> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String, ScanDecision>{};
    final out = <String, ScanDecision>{};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return out;
    }
    if (decoded is! Map) return out;
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) continue;
      final decision = ScanDecision.fromWire(value);
      if (decision == null || decision == ScanDecision.reset) continue;
      out[key] = decision;
    }
    return out;
  }
}
