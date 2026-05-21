import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model_descriptor.dart';
import 'model_download_progress.dart';
import '../platform/nsfw_platform_interface.dart';

/// Lifecycle states a model can be in.
enum ModelStatus {
  /// The native side has no record of this model id.
  unknown,

  /// Model exists in the registry but its bytes aren't on the device yet.
  missing,

  /// Model is currently being downloaded.
  downloading,

  /// Model is on disk but hasn't been loaded into memory.
  downloaded,

  /// Model is loaded and warm — first scan will be fast.
  ready,

  /// Last load attempt failed. See [ModelStateSnapshot.error].
  failed;
}

/// Immutable snapshot of one model's current state.
@immutable
class ModelStateSnapshot {
  final String modelId;
  final ModelStatus status;
  final double? downloadFraction; // 0..1 while downloading; null otherwise
  final int? sizeBytes;
  final String? error;

  const ModelStateSnapshot({
    required this.modelId,
    required this.status,
    this.downloadFraction,
    this.sizeBytes,
    this.error,
  });

  @override
  String toString() => 'ModelStateSnapshot($modelId, ${status.name}'
      '${downloadFraction != null ? ', ${(downloadFraction! * 100).toStringAsFixed(1)}%' : ''}'
      '${error != null ? ', error=$error' : ''})';
}

/// High-level model lifecycle facade. Wraps the bare per-method APIs on
/// [NsfwPlatformInterface] with batch-preload, ensure-ready (download-then-
/// load), and a tracked state machine you can subscribe to from UI.
///
/// Obtain via `NsfwDetector.instance.models`. Do not construct directly.
class NsfwModelManager {
  NsfwModelManager(this._platform, this._downloadProgress);

  final NsfwPlatformInterface _platform;
  final Stream<ModelDownloadProgress> _downloadProgress;

  final Map<String, ModelStateSnapshot> _state = {};
  final StreamController<ModelStateSnapshot> _changes =
      StreamController.broadcast();
  StreamSubscription<ModelDownloadProgress>? _progressSub;

  /// Broadcast stream of state transitions for every model the manager
  /// tracks. Subscribe before triggering downloads to capture the first
  /// progress events.
  Stream<ModelStateSnapshot> get changes {
    _ensureProgressSub();
    return _changes.stream;
  }

  /// Returns the cached snapshot for [modelId], or `unknown` if the manager
  /// has never seen it. Does not hit the native side — call [refresh] to
  /// reconcile against the registry.
  ModelStateSnapshot snapshot(String modelId) =>
      _state[modelId] ??
      ModelStateSnapshot(modelId: modelId, status: ModelStatus.unknown);

  /// All cached snapshots.
  List<ModelStateSnapshot> get snapshots =>
      List.unmodifiable(_state.values);

  /// Pulls the native model registry and refreshes the cached snapshots for
  /// each known descriptor. Returns the full list.
  Future<List<ModelDescriptor>> refresh() async {
    final descriptors = await _platform.availableModels();
    for (final d in descriptors) {
      final wasReady = _state[d.id]?.status == ModelStatus.ready;
      final next = d.isAvailable
          ? (wasReady ? ModelStatus.ready : ModelStatus.downloaded)
          : ModelStatus.missing;
      _publish(ModelStateSnapshot(
        modelId: d.id,
        status: next,
        sizeBytes: d.downloadSizeBytes > 0 ? d.downloadSizeBytes : null,
      ));
    }
    return descriptors;
  }

  /// Preloads (warms) [modelId] — equivalent to
  /// [NsfwPlatformInterface.preloadModel] but tracks status transitions so
  /// the UI can render an accurate state pill.
  Future<void> preload(String modelId) async {
    _publish(ModelStateSnapshot(
      modelId: modelId,
      status: ModelStatus.downloading, // close enough — "loading into memory"
    ));
    try {
      await _platform.preloadModel(modelId);
      _publish(ModelStateSnapshot(
        modelId: modelId,
        status: ModelStatus.ready,
      ));
    } catch (e) {
      _publish(ModelStateSnapshot(
        modelId: modelId,
        status: ModelStatus.failed,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  /// Sequentially preloads every id in [modelIds]. Returns the ids that
  /// loaded successfully; any errors are routed through [onError] (when
  /// provided) and otherwise swallowed.
  Future<List<String>> preloadAll(
    List<String> modelIds, {
    void Function(String modelId, Object error)? onError,
  }) async {
    final ok = <String>[];
    for (final id in modelIds) {
      try {
        await preload(id);
        ok.add(id);
      } catch (e) {
        if (onError != null) {
          onError(id, e);
        }
      }
    }
    return ok;
  }

  /// Downloads [modelId] when missing, then preloads it. Returns once the
  /// model is ready. [onProgress] is fed every progress event while the
  /// download is in flight.
  Future<void> ensureReady(
    String modelId, {
    void Function(ModelDownloadProgress)? onProgress,
    String? overrideUrl,
  }) async {
    final descriptors = await _platform.availableModels();
    final descriptor =
        descriptors.where((d) => d.id == modelId).cast<ModelDescriptor?>().firstWhere(
              (_) => true,
              orElse: () => null,
            );

    if (descriptor == null) {
      _publish(ModelStateSnapshot(
        modelId: modelId,
        status: ModelStatus.failed,
        error: 'Unknown model id',
      ));
      throw StateError('Unknown model id: $modelId');
    }

    if (descriptor.requiresDownload && !descriptor.isDownloaded) {
      _publish(ModelStateSnapshot(
        modelId: modelId,
        status: ModelStatus.downloading,
        downloadFraction: 0,
        sizeBytes: descriptor.downloadSizeBytes,
      ));

      late StreamSubscription<ModelDownloadProgress> sub;
      final completer = Completer<void>();
      sub = _downloadProgress.where((p) => p.modelId == modelId).listen(
        (p) {
          onProgress?.call(p);
          _publish(ModelStateSnapshot(
            modelId: modelId,
            status: p.isComplete ? ModelStatus.downloaded : ModelStatus.downloading,
            downloadFraction: p.fraction,
            sizeBytes: p.totalBytes,
            error: p.error,
          ));
          if (p.isComplete && !completer.isCompleted) {
            completer.complete();
          }
          if (p.error != null && !completer.isCompleted) {
            completer.completeError(StateError(p.error!));
          }
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );

      try {
        final ok = await _platform.downloadModel(modelId, url: overrideUrl);
        if (!ok && !completer.isCompleted) {
          completer.completeError(StateError('Native rejected download'));
        }
        await completer.future;
      } finally {
        await sub.cancel();
      }
    }

    await preload(modelId);
  }

  /// Deletes the local copy of [modelId] (if downloadable) and resets state.
  Future<void> remove(String modelId) async {
    await _platform.deleteModel(modelId);
    _publish(ModelStateSnapshot(
      modelId: modelId,
      status: ModelStatus.missing,
    ));
  }

  /// Override the download URL for [modelId]. Persists in native settings.
  Future<void> setUrl(String modelId, String url) =>
      _platform.setModelUrl(modelId, url);

  void _ensureProgressSub() {
    _progressSub ??= _downloadProgress.listen((p) {
      final current = _state[p.modelId];
      if (current == null) return; // not tracked yet
      _publish(ModelStateSnapshot(
        modelId: p.modelId,
        status: p.isComplete ? ModelStatus.downloaded : ModelStatus.downloading,
        downloadFraction: p.fraction,
        sizeBytes: p.totalBytes ?? current.sizeBytes,
        error: p.error,
      ));
    }, onError: (_) {/* see [NsfwDetector.downloadProgress] */});
  }

  void _publish(ModelStateSnapshot snap) {
    _state[snap.modelId] = snap;
    if (!_changes.isClosed) _changes.add(snap);
  }

  /// Disposes the internal stream controllers. Mostly relevant for tests; the
  /// detector singleton lives for the app's lifetime in production.
  @visibleForTesting
  Future<void> dispose() async {
    await _progressSub?.cancel();
    _progressSub = null;
    await _changes.close();
  }
}
