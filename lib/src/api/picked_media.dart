import 'package:flutter/foundation.dart';

import 'media_item.dart';

// Re-export for backwards compatibility — historically `MediaPickerType` lived
// in this file. Consumers importing it from `picked_media.dart` keep working.
export 'media_picker_type.dart';

/// One item returned by [NsfwDetector.pickMedia].
///
/// [localId] is the platform-native identifier you can pass back into
/// [NsfwDetector.scanAsset] to classify the item later — `PHAsset.localIdentifier`
/// on iOS, `MediaStore` content URI string on Android.
@immutable
class PickedMedia {
  final String localId;

  /// Media type of the picked item. Stage 3a breaking change: this is now a
  /// strongly-typed [MediaType] enum instead of the previous `String`. The
  /// native picker only surfaces `image` or `video` here, but the field is
  /// typed as [MediaType] so callers can compare directly with values from
  /// [MediaItem.type].
  final MediaType mediaType;
  final String? filePath;
  final int? width;
  final int? height;
  final int? durationMs;

  const PickedMedia({
    required this.localId,
    required this.mediaType,
    this.filePath,
    this.width,
    this.height,
    this.durationMs,
  });

  factory PickedMedia.fromMap(Map<dynamic, dynamic> map) => PickedMedia(
        localId: map['localId'] as String,
        mediaType: MediaType.fromString(
            map['mediaType'] as String? ?? 'image'),
        filePath: map['filePath'] as String?,
        width: (map['width'] as num?)?.toInt(),
        height: (map['height'] as num?)?.toInt(),
        durationMs: (map['durationMs'] as num?)?.toInt(),
      );

  /// Returns a copy of this [PickedMedia] with selected fields replaced.
  PickedMedia copyWith({
    String? localId,
    MediaType? mediaType,
    String? filePath,
    int? width,
    int? height,
    int? durationMs,
  }) =>
      PickedMedia(
        localId: localId ?? this.localId,
        mediaType: mediaType ?? this.mediaType,
        filePath: filePath ?? this.filePath,
        width: width ?? this.width,
        height: height ?? this.height,
        durationMs: durationMs ?? this.durationMs,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is PickedMedia &&
        localId == other.localId &&
        mediaType == other.mediaType &&
        filePath == other.filePath &&
        width == other.width &&
        height == other.height &&
        durationMs == other.durationMs;
  }

  @override
  int get hashCode =>
      Object.hash(localId, mediaType, filePath, width, height, durationMs);

  @override
  String toString() =>
      'PickedMedia(localId: $localId, type: ${mediaType.name}, '
      'filePath: $filePath, width: $width, height: $height, '
      'durationMs: $durationMs)';
}
