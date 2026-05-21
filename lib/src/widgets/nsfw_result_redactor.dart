import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../api/body_part_detection.dart';
import '../api/scan_result.dart';
import 'nsfw_result_badge.dart';

/// Strategy used to obscure flagged regions.
enum NsfwRedactionStyle {
  /// Standard Gaussian-style blur via [BackdropFilter].
  blur,

  /// Solid colour overlay — useful when the underlying child can't be
  /// re-rendered behind a [BackdropFilter] (e.g. platform views).
  solid,
}

/// Renders [child] with NSFW content redacted based on a [ScanResult].
///
/// Behaviour:
///   * `result == null` or `!result.isNsfw` → [child] is rendered as-is.
///   * `result.isNsfw` AND `result.hasDetections` → a per-detection overlay
///     is drawn over each box in [ScanResult.detections].
///   * `result.isNsfw` AND no detections → the entire [child] is covered
///     with a single blur / solid mask.
///
/// The redactor sizes its overlays from the layout box it receives — pass
/// a [sourceSize] only if you need to record the intrinsic aspect (e.g. for
/// debugging or downstream layout). Bounding boxes are always projected as
/// normalised fractions of the laid-out widget size.
class NsfwResultRedactor extends StatelessWidget {
  /// The image / media widget being redacted. Typically `Image.memory`,
  /// `Image.file`, or `Image.asset` depending on the source.
  final Widget child;

  /// Classification result. When `null` the redactor renders [child]
  /// without overlays (useful while a scan is in-flight).
  final ScanResult? result;

  /// Optional intrinsic size of the source media. Currently used only as a
  /// debug hint — bounding boxes are normalized in `[0, 1]` and projected
  /// against the laid-out widget size.
  final Size? sourceSize;

  /// Blur sigma used when [style] is [NsfwRedactionStyle.blur].
  final double blurSigma;

  /// Tint drawn on top of the blur (or as the solid fill when
  /// [style] is [NsfwRedactionStyle.solid]).
  final Color overlayColor;

  /// Redaction strategy. Defaults to [NsfwRedactionStyle.blur].
  final NsfwRedactionStyle style;

  /// Optional badge overlay drawn over the top-right corner. Defaults to a
  /// compact [NsfwResultBadge].
  final Widget? badge;

  /// Whether to mask the entire image when the scan returned no detections
  /// but the classifier flagged the image as NSFW. Defaults to true.
  final bool maskWholeImageWhenNoDetections;

  const NsfwResultRedactor({
    super.key,
    required this.child,
    required this.result,
    this.sourceSize,
    this.blurSigma = 20,
    this.overlayColor = const Color(0x66000000),
    this.style = NsfwRedactionStyle.blur,
    this.badge,
    this.maskWholeImageWhenNoDetections = true,
  });

  /// Convenience constructor binding [Image.memory] as the child.
  NsfwResultRedactor.bytes({
    Key? key,
    required Uint8List bytes,
    required ScanResult? result,
    Size? sourceSize,
    double blurSigma = 20,
    Color overlayColor = const Color(0x66000000),
    NsfwRedactionStyle style = NsfwRedactionStyle.blur,
    Widget? badge,
    BoxFit fit = BoxFit.cover,
    bool maskWholeImageWhenNoDetections = true,
  }) : this(
          key: key,
          child: Image.memory(bytes, fit: fit, gaplessPlayback: true),
          result: result,
          sourceSize: sourceSize,
          blurSigma: blurSigma,
          overlayColor: overlayColor,
          style: style,
          badge: badge,
          maskWholeImageWhenNoDetections: maskWholeImageWhenNoDetections,
        );

  /// Convenience constructor binding [Image.file] as the child. Not for
  /// use on web (uses `dart:io`).
  NsfwResultRedactor.file({
    Key? key,
    required String path,
    required ScanResult? result,
    Size? sourceSize,
    double blurSigma = 20,
    Color overlayColor = const Color(0x66000000),
    NsfwRedactionStyle style = NsfwRedactionStyle.blur,
    Widget? badge,
    BoxFit fit = BoxFit.cover,
    bool maskWholeImageWhenNoDetections = true,
  }) : this(
          key: key,
          child: Image(
            image: FileImage(io.File(path)),
            fit: fit,
            gaplessPlayback: true,
          ),
          result: result,
          sourceSize: sourceSize,
          blurSigma: blurSigma,
          overlayColor: overlayColor,
          style: style,
          badge: badge,
          maskWholeImageWhenNoDetections: maskWholeImageWhenNoDetections,
        );

  /// Convenience constructor binding [Image.asset] as the child.
  NsfwResultRedactor.asset({
    Key? key,
    required String assetName,
    required ScanResult? result,
    Size? sourceSize,
    double blurSigma = 20,
    Color overlayColor = const Color(0x66000000),
    NsfwRedactionStyle style = NsfwRedactionStyle.blur,
    Widget? badge,
    BoxFit fit = BoxFit.cover,
    bool maskWholeImageWhenNoDetections = true,
  }) : this(
          key: key,
          child: Image.asset(assetName, fit: fit, gaplessPlayback: true),
          result: result,
          sourceSize: sourceSize,
          blurSigma: blurSigma,
          overlayColor: overlayColor,
          style: style,
          badge: badge,
          maskWholeImageWhenNoDetections: maskWholeImageWhenNoDetections,
        );

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null || !r.isNsfw) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutSize = Size(constraints.maxWidth, constraints.maxHeight);
        final hasDetections = r.hasDetections;

        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (hasDetections)
              ..._buildDetectionOverlays(r.detections!, layoutSize)
            else if (maskWholeImageWhenNoDetections)
              _buildFullOverlay(),
            Positioned(
              top: 8,
              right: 8,
              child: badge ?? NsfwResultBadge(result: r),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFullOverlay() {
    return Positioned.fill(child: _maskBox());
  }

  List<Widget> _buildDetectionOverlays(
    List<BodyPartDetection> detections,
    Size layoutSize,
  ) {
    final overlays = <Widget>[];
    for (final det in detections) {
      // Skip detections that aren't NSFW — the badge will still convey the
      // overall verdict.
      if (det.aggregatedCategory.isSafe) continue;
      final box = det.box;
      final left = box.x * layoutSize.width;
      final top = box.y * layoutSize.height;
      final width = box.width * layoutSize.width;
      final height = box.height * layoutSize.height;
      overlays.add(Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: _maskBox(),
      ));
    }
    if (overlays.isEmpty && maskWholeImageWhenNoDetections) {
      overlays.add(_buildFullOverlay());
    }
    return overlays;
  }

  Widget _maskBox() {
    if (style == NsfwRedactionStyle.solid) {
      return DecoratedBox(decoration: BoxDecoration(color: overlayColor));
    }
    // Blur via BackdropFilter; ClipRect prevents the blur bleeding to siblings.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(decoration: BoxDecoration(color: overlayColor)),
      ),
    );
  }
}
