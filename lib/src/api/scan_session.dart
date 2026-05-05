import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'scan_result.dart';
import 'scan_progress.dart';
import 'scan_summary.dart';
import 'scan_configuration.dart';
import '../platform/nsfw_platform_interface.dart';

class ScanSession {
  final ScanConfiguration _config;
  final NsfwPlatformInterface _platform;

  final _resultsController = StreamController<ScanResult>.broadcast();
  final _progressController = StreamController<ScanProgress>.broadcast();
  final _summaryCompleter = Completer<ScanSummary>();

  StreamSubscription<Map<dynamic, dynamic>>? _eventSub;

  bool _isRunning = false;
  bool _isCancelled = false;

  int _nsfwCount = 0;
  int _skippedCount = 0;
  int _failedCount = 0;
  int _totalCount = 0;
  DateTime? _startTime;

  ScanSession._({
    required ScanConfiguration config,
    required NsfwPlatformInterface platform,
  })  : _config = config,
        _platform = platform;

  static Future<ScanSession> start({
    required ScanConfiguration config,
    required NsfwPlatformInterface platform,
  }) async {
    final session = ScanSession._(config: config, platform: platform);
    await session._begin();
    return session;
  }

  static Future<ScanSession> startPicker({
    required ScanConfiguration config,
    required NsfwPlatformInterface platform,
    required int maxItems,
  }) async {
    final session = ScanSession._(config: config, platform: platform);
    await session._beginPicker(maxItems);
    return session;
  }

  Stream<ScanResult> get results => _resultsController.stream;
  Stream<ScanProgress> get progress => _progressController.stream;
  Future<ScanSummary> get done => _summaryCompleter.future;
  bool get isRunning => _isRunning;
  bool get isCancelled => _isCancelled;

  Future<void> _beginPicker(int maxItems) async {
    _isRunning = true;
    _startTime = DateTime.now();
    _eventSub = _platform.scanEventStream.listen(
      _handleEvent, onError: _handleError, onDone: _handleDone,
    );
    await _platform.startPickAndScan(_config, maxItems);
  }

  Future<void> _begin() async {
    _isRunning = true;
    _startTime = DateTime.now();

    if (kDebugMode) {
      dev.log(
        '[NSFW] Starting scan: model=${_config.modelId}, '
        'confidence=${_config.confidenceThreshold}, '
        'detConf=${_config.detectionConfidenceThreshold}, '
        'iou=${_config.iouThreshold}',
        name: 'nsfw_detect_ios',
      );
    }

    _eventSub = _platform.scanEventStream.listen(
      _handleEvent,
      onError: _handleError,
      onDone: _handleDone,
    );

    await _platform.startScan(_config);
  }

  void _handleEvent(Map<dynamic, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'result':
        _ingestResult(event);

      case 'results':
        // Batched form emitted by native EventBatcher — fan out to ingest each item.
        final items = event['items'] as List<dynamic>?;
        if (items != null) {
          for (final item in items) {
            if (item is Map) _ingestResult(item);
          }
        }

      case 'progress':
        final progress = ScanProgress.fromMap(event);
        _totalCount = progress.totalCount;
        _progressController.add(progress);
        if (progress.isComplete && !_summaryCompleter.isCompleted) {
          _finish(cancelled: false);
        }

      case 'error':
        final msg = event['message'] as String? ?? 'Unknown scan error';
        if (kDebugMode) {
          dev.log('[NSFW] SCAN ERROR: $msg', name: 'nsfw_detect_ios');
        }
        _handleError(Exception(msg));
    }
  }

  void _ingestResult(Map<dynamic, dynamic> event) {
    if (kDebugMode) {
      final labels = (event['labels'] as List<dynamic>?)
          ?.map((l) => '${l['category']}=${((l['confidence'] as num) * 100).toStringAsFixed(1)}%')
          .join(', ');
      final detCount = (event['detections'] as List<dynamic>?)?.length ?? 0;
      dev.log(
        '[NSFW] Result: model=${_config.modelId} labels=[$labels] detections=$detCount',
        name: 'nsfw_detect_ios',
      );
      final debugInfo = event['debugInfo'] as Map?;
      if (debugInfo != null) {
        dev.log('[NSFW] DEBUG: $debugInfo', name: 'nsfw_detect_ios');
      }
      if (detCount > 0) {
        for (final d in (event['detections'] as List<dynamic>).take(5)) {
          dev.log(
            '[NSFW]   -> ${d['className']} [${d['category']}] conf=${((d['confidence'] as num) * 100).toStringAsFixed(1)}%',
            name: 'nsfw_detect_ios',
          );
        }
      }
    }
    final result = ScanResult.fromMap(event, confidenceThreshold: _config.confidenceThreshold);
    if (result.status == ScanStatus.failed) {
      _failedCount++;
      if (kDebugMode) {
        dev.log(
          '[NSFW] SCAN FAILED: ${result.item.localIdentifier} '
          '— ${result.errorMessage ?? "unknown error"}',
          name: 'nsfw_detect_ios',
        );
      }
    } else if (result.status == ScanStatus.skipped) {
      _skippedCount++;
    } else if (result.isNsfw) {
      _nsfwCount++;
    }
    _resultsController.add(result);
  }

  void _handleError(Object error) {
    if (!_resultsController.isClosed) _resultsController.addError(error);
  }

  void _handleDone() {
    if (!_summaryCompleter.isCompleted) _finish(cancelled: _isCancelled);
  }

  void _finish({required bool cancelled}) {
    _isRunning = false;
    final elapsed =
        _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;

    final summary = ScanSummary(
      totalScanned: _totalCount,
      nsfwCount: _nsfwCount,
      skippedCount: _skippedCount,
      failedCount: _failedCount,
      elapsed: elapsed,
      wasCancelled: cancelled,
    );

    _summaryCompleter.complete(summary);
    _eventSub?.cancel();
    _resultsController.close();
    _progressController.close();
  }

  Future<void> cancel() async {
    if (!_isRunning) return;
    _isCancelled = true;
    await _platform.cancelScan();
    // Ensure we finish immediately — don't wait for native onDone
    if (!_summaryCompleter.isCompleted) {
      _finish(cancelled: true);
    }
  }
}
