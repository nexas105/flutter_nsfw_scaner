import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/nsfw_platform_interface.dart';
import 'media_item.dart';
import 'nsfw_detector.dart';
import 'scan_configuration.dart';
import 'scan_progress.dart';
import 'scan_result.dart';
import 'scan_session.dart';

/// State holder for an interactive photo-library NSFW scan flow.
///
/// Wraps the imperative [NsfwDetector] surface (permission, scan lifecycle,
/// streamed results) into a [ChangeNotifier] that's safe to consume from a
/// Flutter widget. Hosts that want full control over the scan UI can build
/// their own widgets on top of this controller; the bundled `NsfwGalleryView`
/// uses it internally.
///
/// The controller owns UI state and stream subscriptions only; classification
/// still happens through [NsfwDetector] and the native on-device scanner.
/// Exposed results are probabilistic and should be reviewed with the same
/// threshold and false-positive expectations as raw [ScanResult] values.
///
/// Lifecycle
/// ---------
/// * Construct with an initial [ScanConfiguration]. The controller does not
///   probe permission or start a scan automatically — call [checkPermission]
///   first, then [startScan] when ready. If [autoStartOnPermission] is true,
///   the controller will call [startScan] after [requestPermission] /
///   [checkPermission] completes with an authorized status.
/// * [updateConfig] swaps in a new configuration; the change does not
///   restart an in-flight scan, but is picked up on the next [startScan].
/// * Always call [dispose] when the host widget is unmounted; the controller
///   cancels stream subscriptions and the underlying [ScanSession]. After
///   dispose, [notifyListeners] becomes a safe no-op (`_disposed` guard).
class NsfwScanController extends ChangeNotifier {
  NsfwScanController({
    ScanConfiguration initialConfig = const ScanConfiguration(),
    this.autoStartOnPermission = false,
    NsfwDetector? detector,
  })  : _config = initialConfig,
        _detector = detector ?? NsfwDetector.instance;

  final NsfwDetector _detector;

  /// When true, [requestPermission] / [checkPermission] auto-start a scan
  /// on success (authorized | limited). The host can still call
  /// [startScan] manually; the flag only governs the implicit follow-up.
  final bool autoStartOnPermission;

  // ── State ────────────────────────────────────────────────────────────────

  PhotoLibraryPermissionStatus? _permissionStatus;
  ScanSession? _session;
  ScanConfiguration _config;
  ScanProgress? _lastProgress;
  bool _wasStopped = false;
  bool _disposed = false;

  // Ordered list of items observed (insertion order = result-arrival order)
  final List<MediaItem> _items = [];
  // Map from localIdentifier -> latest ScanResult for that asset
  final Map<String, ScanResult> _results = {};

  StreamSubscription<ScanResult>? _resultSub;
  StreamSubscription<ScanProgress>? _progressSub;

  final StreamController<ScanProgress> _progressStreamController =
      StreamController<ScanProgress>.broadcast();

  // ── Public read-only accessors ──────────────────────────────────────────

  PhotoLibraryPermissionStatus? get permissionStatus => _permissionStatus;
  ScanSession? get session => _session;
  ScanConfiguration get config => _config;
  ScanProgress? get lastProgress => _lastProgress;
  bool get wasStopped => _wasStopped;
  bool get isScanning => _session?.isRunning == true;

  /// Insertion-ordered view onto every asset that has reported a result so
  /// far. Stable across scans when [startScan(resume: true)] is used.
  List<MediaItem> get items => List.unmodifiable(_items);

  /// Map keyed by `MediaItem.localIdentifier`. Lookups stay O(1) for tile
  /// rendering. The map is unmodifiable from the outside.
  Map<String, ScanResult> get results => Map.unmodifiable(_results);

  /// Broadcast stream that mirrors progress updates from the active session.
  /// Cancelling the host's listener does not stop the underlying scan;
  /// call [stopScan] for that.
  Stream<ScanProgress> get progressStream => _progressStreamController.stream;

  // ── Mutators ────────────────────────────────────────────────────────────

  /// Replace the active configuration. Does not affect a scan that is
  /// currently running — call [stopScan] + [startScan] to apply during a
  /// scan, or just call [startScan] when no scan is in flight.
  void updateConfig(ScanConfiguration config) {
    if (_config == config) return;
    _config = config;
    _safeNotify();
  }

  Future<void> checkPermission() async {
    final status = await _detector.checkPermission();
    if (_disposed) return;
    _permissionStatus = status;
    _safeNotify();
    if (autoStartOnPermission && _isAuthorized(status)) {
      await startScan();
    }
  }

  Future<void> requestPermission() async {
    final status = await _detector.requestPermission();
    if (_disposed) return;
    _permissionStatus = status;
    _safeNotify();
    if (_isAuthorized(status)) {
      await startScan();
    }
  }

  Future<void> startScan({bool resume = false}) async {
    if (isScanning) return;

    if (!resume) {
      _items.clear();
      _results.clear();
      _lastProgress = null;
    }
    _wasStopped = false;
    _safeNotify();

    final scanConfig =
        resume ? _config.copyWith(resumeFromCheckpoint: true) : _config;

    final session = await _detector.startScan(scanConfig);
    if (_disposed) {
      // Controller disposed mid-startup — abort the freshly-started session.
      await session.cancel();
      return;
    }
    _session = session;
    _safeNotify();

    await _resultSub?.cancel();
    await _progressSub?.cancel();

    _resultSub = session.results.listen((result) {
      if (_disposed) return;
      final id = result.item.localIdentifier;
      if (!_results.containsKey(id)) _items.add(result.item);
      _results[id] = result;
      _safeNotify();
    });

    _progressSub = session.progress.listen((p) {
      if (_disposed) return;
      _lastProgress = p;
      if (!_progressStreamController.isClosed) {
        _progressStreamController.add(p);
      }
      _safeNotify();
    });

    // Notify when the scan finishes so consumers can refresh derived state
    // (e.g. `isScanning` flips back to false). The summary itself isn't
    // exposed here — hosts that care should listen to `session.done`
    // directly via [session].
    session.done.then((_) {
      if (_disposed) return;
      _safeNotify();
    });
  }

  Future<void> stopScan() async {
    final s = _session;
    if (s == null || !s.isRunning) return;
    await s.cancel();
    if (_disposed) return;
    _wasStopped = true;
    _safeNotify();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _resultSub?.cancel();
    await _progressSub?.cancel();
    _resultSub = null;
    _progressSub = null;
    if (!_progressStreamController.isClosed) {
      await _progressStreamController.close();
    }
    final s = _session;
    if (s != null && s.isRunning) {
      // Best-effort cancel; ignore errors from a session that's already
      // tearing itself down.
      try {
        await s.cancel();
      } catch (_) {}
    }
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  static bool _isAuthorized(PhotoLibraryPermissionStatus s) =>
      s == PhotoLibraryPermissionStatus.authorized ||
      s == PhotoLibraryPermissionStatus.limited;
}
