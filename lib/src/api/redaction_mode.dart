/// How [NsfwDetector.redactBytes] / [NsfwDetector.redactFile] should obscure
/// flagged regions of an image.
///
/// When the source [ScanResult] carries `detections` (i.e. came from a
/// detection-mode scan), only the per-detection bounding boxes are redacted.
/// Otherwise the whole image is redacted as a fallback — for classifier-only
/// scans there's no spatial information to localise the redaction.
enum RedactionMode {
  /// Gaussian blur. Intensity (0.0–1.0) maps to a blur radius in pixels.
  /// Default — fastest and visually softest.
  blur,

  /// Nearest-neighbour downscale then upscale, producing a mosaic effect.
  /// Intensity maps to mosaic block size.
  pixelate,

  /// Solid fill (black by default). Intensity is ignored. Strongest signal,
  /// fully opaque — useful for moderation review screens.
  blackBox;

  /// Wire-level discriminator used in the native MethodChannel call.
  String get wireValue => switch (this) {
        RedactionMode.blur => 'blur',
        RedactionMode.pixelate => 'pixelate',
        RedactionMode.blackBox => 'blackBox',
      };

  static RedactionMode fromString(String? s) => switch (s) {
        'pixelate' => RedactionMode.pixelate,
        'blackBox' => RedactionMode.blackBox,
        _ => RedactionMode.blur,
      };
}
