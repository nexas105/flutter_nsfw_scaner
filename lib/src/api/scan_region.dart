import 'package:flutter/foundation.dart';

/// A rectangular sub-region of an image, expressed in normalized coordinates
/// in `[0, 1]` with origin top-left. Matches the convention used by
/// `BoundingBox` and the native detectors.
///
/// Pass a [ScanRegion] to `NsfwDetector.scanFile` / `scanBytes` / `scanAsset`
/// (or set it on `ScanConfiguration.region` / `CameraConfiguration.region`)
/// to instruct the native scanner to crop the source media to this rectangle
/// before classification. Useful for skipping watermarks / overlays or
/// focusing on a known content area (e.g. a profile-card photo embedded in a
/// larger composite).
///
/// The native side MAY ignore this field if it isn't yet implemented for the
/// requesting platform — in that case the full image is scanned.
@immutable
class ScanRegion {
  /// Top-left x coordinate, normalized `[0, 1]`.
  final double x;

  /// Top-left y coordinate, normalized `[0, 1]`.
  final double y;

  /// Region width, normalized `[0, 1]`. `x + width` must be `<= 1`.
  final double width;

  /// Region height, normalized `[0, 1]`. `y + height` must be `<= 1`.
  final double height;

  const ScanRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  })  : assert(x >= 0.0 && x <= 1.0, 'x must be in [0.0, 1.0]'),
        assert(y >= 0.0 && y <= 1.0, 'y must be in [0.0, 1.0]'),
        assert(width >= 0.0 && width <= 1.0, 'width must be in [0.0, 1.0]'),
        assert(height >= 0.0 && height <= 1.0, 'height must be in [0.0, 1.0]'),
        assert(x + width <= 1.0 + 1e-9, 'x + width must be <= 1.0'),
        assert(y + height <= 1.0 + 1e-9, 'y + height must be <= 1.0');

  /// Convenience for the full image — `(0, 0, 1, 1)`.
  factory ScanRegion.full() =>
      const ScanRegion(x: 0, y: 0, width: 1, height: 1);

  /// Right edge of the region (`x + width`).
  double get right => x + width;

  /// Bottom edge of the region (`y + height`).
  double get bottom => y + height;

  /// True iff this region covers the entire image (`0,0,1,1`).
  bool get isFull => x == 0 && y == 0 && width == 1 && height == 1;

  /// JSON-safe map (also used as the method-channel `roi` argument).
  Map<String, double> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  /// Symmetric with [toJson]. Missing / malformed values fall back to 0 for
  /// origin and 1 for extent so the result is at worst "scan the full image".
  factory ScanRegion.fromJson(Map<dynamic, dynamic> json) {
    double parse(Object? v, double fallback) {
      if (v is num) {
        final d = v.toDouble();
        if (d.isFinite) return d.clamp(0.0, 1.0);
      }
      return fallback;
    }

    return ScanRegion(
      x: parse(json['x'], 0),
      y: parse(json['y'], 0),
      width: parse(json['width'], 1),
      height: parse(json['height'], 1),
    );
  }

  /// Returns a copy with selected fields replaced.
  ScanRegion copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
  }) =>
      ScanRegion(
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other.runtimeType != runtimeType) return false;
    return other is ScanRegion &&
        x == other.x &&
        y == other.y &&
        width == other.width &&
        height == other.height;
  }

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'ScanRegion(x: $x, y: $y, width: $width, height: $height)';
}
