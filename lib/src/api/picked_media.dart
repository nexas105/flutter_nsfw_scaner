import 'package:flutter/foundation.dart';

/// Filter passed to [NsfwDetector.pickMedia].
enum MediaPickerType {
  image('image'),
  video('video'),
  any('any');

  const MediaPickerType(this.wireValue);
  final String wireValue;
}

/// One item returned by [NsfwDetector.pickMedia].
///
/// [localId] is the platform-native identifier you can pass back into
/// [NsfwDetector.scanAsset] to classify the item later — `PHAsset.localIdentifier`
/// on iOS, `MediaStore` content URI string on Android.
@immutable
class PickedMedia {
  final String localId;
  final String mediaType; // "image" or "video"
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
        mediaType: map['mediaType'] as String? ?? 'image',
        filePath: map['filePath'] as String?,
        width: (map['width'] as num?)?.toInt(),
        height: (map['height'] as num?)?.toInt(),
        durationMs: (map['durationMs'] as num?)?.toInt(),
      );
}
