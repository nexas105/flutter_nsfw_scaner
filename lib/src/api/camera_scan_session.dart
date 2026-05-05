import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';

import 'camera_configuration.dart';
import 'camera_frame_result.dart';
import 'camera_exceptions.dart';
import '../platform/nsfw_platform_interface.dart';

/// Live camera scan session.
///
/// Streams [CameraFrameResult] events as frames are classified on-device.
/// No progress tracking or summary — camera frames are fire-and-forget.
///
/// Errors (permission denied, camera unavailable) are emitted as stream
/// errors via [CameraPermissionDeniedException] or [CameraErrorException].
class CameraScanSession {
  final CameraConfiguration _config;
  final NsfwPlatformInterface _platform;

  final _resultsController = StreamController<CameraFrameResult>.broadcast();
  StreamSubscription<Map<dynamic, dynamic>>? _eventSub;

  bool _isRunning = false;

  CameraScanSession._({
    required CameraConfiguration config,
    required NsfwPlatformInterface platform,
  })  : _config = config,
        _platform = platform;

  /// Starts the live camera scan.
  ///
  /// The native side begins capturing frames and classifying them at the
  /// configured [CameraConfiguration.fps]. Results arrive on [results].
  static Future<CameraScanSession> start({
    required CameraConfiguration config,
    required NsfwPlatformInterface platform,
  }) async {
    final session = CameraScanSession._(config: config, platform: platform);
    await session._begin();
    return session;
  }

  /// Stream of classified camera frames.
  ///
  /// Emits a [CameraFrameResult] for each frame processed by the model.
  /// Camera errors arrive as stream errors ([CameraPermissionDeniedException],
  /// [CameraErrorException]).
  Stream<CameraFrameResult> get results => _resultsController.stream;

  /// Whether the session is actively receiving frames.
  bool get isRunning => _isRunning;

  Future<void> _begin() async {
    _isRunning = true;

    if (kDebugMode) {
      dev.log(
        '[NSFW] Starting camera scan: model=${_config.modelId}, '
        'fps=${_config.fps}, mode=${_config.mode.wireValue}',
        name: 'nsfw_detect_ios',
      );
    }

    _eventSub = _platform.scanEventStream.listen(
      _handleEvent,
      onError: _handleError,
      onDone: _handleDone,
    );

    await _platform.startCameraScan(_config);
  }

  void _handleEvent(Map<dynamic, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'cameraFrameResult':
        if (kDebugMode) {
          final labels = (event['labels'] as List<dynamic>?)
              ?.map((l) =>
                  '${l['category']}=${((l['confidence'] as num) * 100).toStringAsFixed(1)}%')
              .join(', ');
          final detCount = (event['detections'] as List<dynamic>?)?.length ?? 0;
          dev.log(
            '[NSFW] Camera frame: labels=[$labels] detections=$detCount',
            name: 'nsfw_detect_ios',
          );
        }
        final result = CameraFrameResult.fromMap(
          event,
          confidenceThreshold: _config.confidenceThreshold,
        );
        _resultsController.add(result);

      case 'cameraPermissionDenied':
        final msg = event['message'] as String? ?? 'Camera permission denied';
        if (kDebugMode) {
          dev.log('[NSFW] Camera permission denied: $msg',
              name: 'nsfw_detect_ios');
        }
        _resultsController
            .addError(const CameraPermissionDeniedException());

      case 'cameraError':
        final msg = event['message'] as String? ?? 'Unknown camera error';
        if (kDebugMode) {
          dev.log('[NSFW] Camera error: $msg', name: 'nsfw_detect_ios');
        }
        _resultsController.addError(CameraErrorException(msg));
    }
  }

  void _handleError(Object error) {
    if (!_resultsController.isClosed) _resultsController.addError(error);
  }

  void _handleDone() {
    _isRunning = false;
  }

  /// Stops the camera scan session.
  ///
  /// No-op if the session is not running.
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    await _platform.stopCameraScan();
    await _eventSub?.cancel();
    _eventSub = null;
    await _resultsController.close();
  }
}
