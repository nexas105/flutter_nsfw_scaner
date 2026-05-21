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

  /// Returns a placeholder [MediaItem] used when a non-gallery surface
  /// (camera frames) needs to construct a transient [ScanResult] for a widget
  /// that was originally designed against the gallery shape — see
  /// `NsfwCameraHud._resultBadgeFromFrame`. Not for general use.
  factory MediaItem.empty() => const MediaItem(
        localIdentifier: '',
        type: MediaType.unknown,
      );

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

  /// Returns a copy of this [MediaItem] with selected fields replaced.
  ///
  /// Passing `null` leaves the existing value unchanged. There is no way to
  /// explicitly null out an optional field via [copyWith] — construct a new
  /// [MediaItem] directly if that's what you need.
  MediaItem copyWith({
    String? localIdentifier,
    MediaType? type,
    DateTime? creationDate,
    Duration? duration,
    int? width,
    int? height,
  }) =>
      MediaItem(
        localIdentifier: localIdentifier ?? this.localIdentifier,
        type: type ?? this.type,
        creationDate: creationDate ?? this.creationDate,
        duration: duration ?? this.duration,
        width: width ?? this.width,
        height: height ?? this.height,
      );

  /// Two [MediaItem]s are equal if they share the same [localIdentifier].
  ///
  /// Metadata fields ([type], [creationDate], [duration], [width], [height])
  /// are views of the underlying asset at a point in time and are intentionally
  /// excluded from equality — same asset, different metadata snapshot is still
  /// the same item. Mirrors how `PHAsset` / `MediaStore` treat asset IDs as keys.
  /// Use [equalsContent] for a deep structural comparison.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MediaItem && localIdentifier == other.localIdentifier;
  }

  @override
  int get hashCode => localIdentifier.hashCode;

  /// Returns `true` iff every metadata field matches [other].
  bool equalsContent(MediaItem other) =>
      localIdentifier == other.localIdentifier &&
      type == other.type &&
      creationDate == other.creationDate &&
      duration == other.duration &&
      width == other.width &&
      height == other.height;

  @override
  String toString() =>
      'MediaItem(localIdentifier: $localIdentifier, type: ${type.name}, '
      'creationDate: $creationDate, duration: $duration, '
      'width: $width, height: $height)';
}
