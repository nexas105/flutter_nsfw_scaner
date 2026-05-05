import 'package:flutter/foundation.dart';

enum MediaType {
  image,
  video,
  livePhoto,
  unknown;

  static MediaType fromString(String s) => switch (s) {
        'image' => MediaType.image,
        'video' => MediaType.video,
        'livePhoto' => MediaType.livePhoto,
        _ => MediaType.unknown,
      };
}

@immutable
class MediaItem {
  final String localIdentifier;
  final MediaType type;
  final DateTime? creationDate;
  final Duration? duration;
  final int? width;
  final int? height;

  const MediaItem({
    required this.localIdentifier,
    required this.type,
    this.creationDate,
    this.duration,
    this.width,
    this.height,
  });

  factory MediaItem.fromMap(Map<dynamic, dynamic> map) => MediaItem(
        localIdentifier: map['localId'] as String,
        type: MediaType.fromString(map['mediaType'] as String? ?? 'unknown'),
        creationDate: map['creationDate'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['creationDate'] as int)
            : null,
        duration: map['durationMs'] != null
            ? Duration(milliseconds: map['durationMs'] as int)
            : null,
        width: map['width'] as int?,
        height: map['height'] as int?,
      );

  Map<String, dynamic> toMap() => {
        'localId': localIdentifier,
        'mediaType': type.name,
        if (creationDate != null) 'creationDate': creationDate!.millisecondsSinceEpoch,
        if (duration != null) 'durationMs': duration!.inMilliseconds,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MediaItem && localIdentifier == other.localIdentifier;

  @override
  int get hashCode => localIdentifier.hashCode;

  @override
  String toString() => 'MediaItem($localIdentifier, ${type.name})';
}
