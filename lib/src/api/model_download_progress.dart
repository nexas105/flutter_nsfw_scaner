import 'package:flutter/foundation.dart';

/// Typed download-progress event emitted by [NsfwDetector.downloadProgress].
/// Native sends one of these per chunk while a model download is in flight.
@immutable
class ModelDownloadProgress {
  final String modelId;
  final double fraction; // 0.0 – 1.0; clamped on construction
  final int bytesDownloaded;
  final int? totalBytes;
  final bool isComplete;
  final String? error;

  const ModelDownloadProgress({
    required this.modelId,
    required this.fraction,
    required this.bytesDownloaded,
    required this.totalBytes,
    this.isComplete = false,
    this.error,
  });

  factory ModelDownloadProgress.fromMap(Map<dynamic, dynamic> map) {
    final modelId = (map['modelId'] as String?) ?? '';
    final bytesDownloaded = _readInt(map['bytesDownloaded']) ?? 0;
    final totalBytes = _readInt(map['totalBytes']);
    final rawFraction = (map['fraction'] as num?)?.toDouble();
    final computed =
        rawFraction ?? (totalBytes != null && totalBytes > 0
            ? (bytesDownloaded / totalBytes)
            : 0.0);
    final clamped = computed.isFinite ? computed.clamp(0.0, 1.0) : 0.0;
    return ModelDownloadProgress(
      modelId: modelId,
      fraction: clamped.toDouble(),
      bytesDownloaded: bytesDownloaded,
      totalBytes: totalBytes,
      isComplete: map['isComplete'] as bool? ?? clamped >= 1.0,
      error: map['error'] as String?,
    );
  }

  static int? _readInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  /// Pretty `12.3 MB / 45.6 MB` — falls back to bytes alone when total
  /// is unknown.
  String get bytesLabel {
    String fmt(int bytes) {
      const units = ['B', 'KB', 'MB', 'GB'];
      var v = bytes.toDouble();
      var i = 0;
      while (v >= 1024 && i < units.length - 1) {
        v /= 1024;
        i++;
      }
      return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
    }

    if (totalBytes != null && totalBytes! > 0) {
      return '${fmt(bytesDownloaded)} / ${fmt(totalBytes!)}';
    }
    return fmt(bytesDownloaded);
  }

  @override
  String toString() =>
      'ModelDownloadProgress($modelId ${(fraction * 100).toStringAsFixed(1)}%, '
      '${isComplete ? 'done' : 'in-flight'}'
      '${error != null ? ', error=$error' : ''})';
}
