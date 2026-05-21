import 'dart:async';
import 'dart:typed_data';

import 'nsfw_detector.dart';
import 'perceptual_cache.dart';
import 'scan_result.dart';

/// Adapter that turns an arbitrary `Stream<Uint8List>` of encoded image frames
/// (JPEG / PNG / WebP — anything Flutter's image codecs can decode) into a
/// throttled `Stream<ScanResult>`.
///
/// Designed for live video pipelines where the source emits frames faster
/// than the model can classify them — common examples:
///
/// * `flutter_webrtc` `MediaStreamTrack.captureFrame()` polled in a timer
/// * `camera` plugin's `startImageStream` after JPEG encoding
/// * Custom WebSocket / RTSP / HLS frame producers
///
/// ### `flutter_webrtc` integration
///
/// `FrameStreamScanner` deliberately does NOT depend on `flutter_webrtc` —
/// glue the two together caller-side:
///
/// ```dart
/// import 'package:flutter_webrtc/flutter_webrtc.dart';
///
/// Stream<Uint8List> webRtcFrameStream(
///   MediaStreamTrack track, {
///   int pollHz = 4,
/// }) {
///   final controller = StreamController<Uint8List>();
///   final period = Duration(milliseconds: (1000 / pollHz).round());
///   late final Timer timer;
///   timer = Timer.periodic(period, (_) async {
///     try {
///       final buffer = await track.captureFrame();
///       controller.add(buffer.asUint8List());
///     } catch (_) {/* track stopped or capture failed — skip */}
///   });
///   controller.onCancel = () => timer.cancel();
///   return controller.stream;
/// }
///
/// final scanner = NsfwDetector.instance.scanFrameStream(
///   frames: webRtcFrameStream(remoteVideoTrack, pollHz: 4),
///   targetFps: 2,
///   earlyExitOnNsfw: true,
///   dedupeCache: NsfwDetector.instance.perceptualCache,
/// );
///
/// final firstNsfw = await scanner.waitForNsfw(
///   timeout: const Duration(seconds: 30),
/// );
/// if (firstNsfw != null) {
///   // moderate the remote peer
/// }
/// await scanner.stop();
/// ```
///
/// ### Backpressure semantics
///
/// * Frames that arrive sooner than `1000 / targetFps` ms after the last
///   accepted frame are dropped silently.
/// * If a scan is still in flight when a new frame is accepted, the new
///   frame is also dropped — the scanner never queues more than one
///   in-flight scan.
/// * When [dedupeCache] is provided, accepted frames that match a recent
///   hash replay the cached `ScanResult` without re-running the model.
class FrameStreamScanner {
  FrameStreamScanner({
    required Stream<Uint8List> frames,
    this.confidenceThreshold = 0.7,
    this.targetFps = 2,
    this.earlyExitOnNsfw = false,
    this.modelId,
    this.dedupeCache,
  })  : assert(targetFps > 0, 'targetFps must be positive'),
        assert(
          confidenceThreshold >= 0.0 && confidenceThreshold <= 1.0,
          'confidenceThreshold must be in [0.0, 1.0]',
        ),
        _frames = frames {
    _attach();
  }

  /// Confidence threshold forwarded to each underlying `scanBytes` call.
  final double confidenceThreshold;

  /// Maximum frames classified per second. Source frames arriving faster than
  /// this are dropped.
  final int targetFps;

  /// If `true`, the input subscription is cancelled and [results] is closed
  /// the first time a [ScanResult] crosses the NSFW threshold.
  final bool earlyExitOnNsfw;

  /// Optional model id; falls back to the detector's default model.
  final String? modelId;

  /// Optional perceptual dedup cache. When set, visually identical frames
  /// re-use the prior `ScanResult` instead of re-running the model.
  final PerceptualCache? dedupeCache;

  final Stream<Uint8List> _frames;
  final StreamController<ScanResult> _out =
      StreamController<ScanResult>.broadcast();
  StreamSubscription<Uint8List>? _sub;

  int _lastAcceptedMs = 0;
  bool _scanInFlight = false;
  bool _stopped = false;

  /// Broadcast stream of classification results. Closes when [stop] is called
  /// or when the input stream completes.
  Stream<ScanResult> get results => _out.stream;

  /// Cancels the input subscription and closes the result stream. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (!_out.isClosed) await _out.close();
  }

  /// Resolves with the first [ScanResult] that crosses the NSFW threshold, or
  /// `null` if [timeout] elapses (or the source closes) first.
  ///
  /// Does NOT stop the scanner — call [stop] separately when you're done.
  Future<ScanResult?> waitForNsfw({Duration? timeout}) {
    final completer = Completer<ScanResult?>();
    late StreamSubscription<ScanResult> sub;
    Timer? timer;

    void finish(ScanResult? value) {
      if (completer.isCompleted) return;
      timer?.cancel();
      // Cancel asynchronously — caller may still want subsequent results.
      // ignore: discarded_futures
      sub.cancel();
      completer.complete(value);
    }

    sub = _out.stream.listen(
      (r) {
        if (r.isNsfw) finish(r);
      },
      onDone: () => finish(null),
      onError: (Object e, StackTrace s) {
        if (!completer.isCompleted) {
          timer?.cancel();
          // ignore: discarded_futures
          sub.cancel();
          completer.completeError(e, s);
        }
      },
    );

    if (timeout != null) {
      timer = Timer(timeout, () => finish(null));
    }
    return completer.future;
  }

  void _attach() {
    final minIntervalMs = (1000 / targetFps).floor();
    _sub = _frames.listen(
      (bytes) {
        if (_stopped) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastAcceptedMs < minIntervalMs) return; // throttle
        if (_scanInFlight) return; // backpressure — drop
        _lastAcceptedMs = now;
        _scanInFlight = true;
        // ignore: discarded_futures
        _processFrame(bytes).whenComplete(() => _scanInFlight = false);
      },
      onError: (Object e, StackTrace s) {
        if (!_out.isClosed) _out.addError(e, s);
      },
      // ignore: unnecessary_lambdas
      onDone: () {
        // ignore: discarded_futures
        stop();
      },
    );
  }

  Future<void> _processFrame(Uint8List bytes) async {
    try {
      ScanResult? result;
      final cache = dedupeCache;
      if (cache != null) {
        final cached = await cache.lookup(bytes);
        if (cached != null) {
          // Replay with a fresh timestamp so subscribers can tell stream
          // events apart on `scannedAt`.
          result = ScanResult(
            item: cached.item,
            status: cached.status,
            labels: cached.labels,
            scannedAt: DateTime.now(),
            confidenceThreshold: cached.confidenceThreshold,
            errorMessage: cached.errorMessage,
            fromCache: true,
            detections: cached.detections,
          );
        }
      }

      result ??= await NsfwDetector.instance.scanBytes(
        bytes,
        modelId: modelId,
        confidenceThreshold: confidenceThreshold,
      );

      if (cache != null && !(result.fromCache)) {
        // Best-effort — failures are non-fatal.
        // ignore: unawaited_futures
        cache.remember(bytes, result);
      }

      if (_stopped || _out.isClosed) return;
      _out.add(result);

      if (earlyExitOnNsfw && result.isNsfw) {
        // ignore: unawaited_futures
        stop();
      }
    } catch (e, s) {
      if (!_out.isClosed) _out.addError(e, s);
    }
  }
}
