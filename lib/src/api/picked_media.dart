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
}
