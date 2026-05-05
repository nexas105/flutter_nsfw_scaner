import 'package:flutter/material.dart';

import '../api/body_part_detection.dart';
import '../api/nsfw_label.dart';
import 'theme/nsfw_theme.dart';

/// Paints NudeNet-style bounding boxes (and optional labels) on top of a
/// thumbnail. Pure `CustomPainter`; place inside a `Stack` over your image,
/// matched to the same `BoxFit` so the normalised box coordinates land on
/// the right pixels.
///
/// Example:
/// ```dart
/// Stack(fit: StackFit.expand, children: [
///   Image.file(file, fit: BoxFit.cover),
///   NsfwDetectionOverlay(detections: result.detections!, theme: theme),
/// ])
/// ```
class NsfwDetectionOverlay extends StatelessWidget {
  /// Boxes to draw. Coordinates are normalised `[0, 1]`, origin top-left.
  final List<BodyPartDetection> detections;

  /// Theme used for per-category colouring. Falls back to defaults.
  final NsfwTheme? theme;

  /// Stroke width for the bounding-box outline.
  final double strokeWidth;

  /// When true, the raw label + confidence is drawn above each box.
  /// Defaults to `true`.
  final bool showLabels;

  /// Optional minimum confidence — boxes below this are not drawn. Useful
  /// for reusing a shared scan result while letting the UI show fewer boxes.
  final double minConfidence;

  const NsfwDetectionOverlay({
    super.key,
    required this.detections,
    this.theme,
    this.strokeWidth = 2.0,
    this.showLabels = true,
    this.minConfidence = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme ?? NsfwTheme.defaults();
    return CustomPaint(
      painter: _DetectionPainter(
        detections: detections,
        theme: t,
        strokeWidth: strokeWidth,
        showLabels: showLabels,
        minConfidence: minConfidence,
      ),
    );
  }
}

class _DetectionPainter extends CustomPainter {
  final List<BodyPartDetection> detections;
  final NsfwTheme theme;
  final double strokeWidth;
  final bool showLabels;
  final double minConfidence;

  _DetectionPainter({
    required this.detections,
    required this.theme,
    required this.strokeWidth,
    required this.showLabels,
    required this.minConfidence,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || detections.isEmpty) return;

    for (final det in detections) {
      if (det.confidence < minConfidence) continue;
      final color = _categoryColor(det.aggregatedCategory);

      final rect = Rect.fromLTWH(
        det.box.x * size.width,
        det.box.y * size.height,
        det.box.width * size.width,
        det.box.height * size.height,
      );

      // Stroke
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawRect(rect, stroke);

      if (!showLabels) continue;

      // Label background + text drawn above the box (or inside if no room).
      final labelText =
          '${det.label} ${(det.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);

      const padX = 4.0;
      const padY = 2.0;
      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top - tp.height - padY * 2 < 0
            ? rect.top
            : rect.top - tp.height - padY * 2,
        tp.width + padX * 2,
        tp.height + padY * 2,
      );

      final bg = Paint()..color = color.withValues(alpha: 0.85);
      canvas.drawRect(labelRect, bg);
      tp.paint(canvas, labelRect.topLeft + const Offset(padX, padY));
    }
  }

  Color _categoryColor(NsfwCategory category) =>
      theme.gallery.categoryColor(category.name);

  @override
  bool shouldRepaint(covariant _DetectionPainter old) =>
      old.detections != detections ||
      old.strokeWidth != strokeWidth ||
      old.showLabels != showLabels ||
      old.minConfidence != minConfidence ||
      old.theme != theme;
}
