import 'package:flutter/material.dart';

import '../api/camera_frame_result.dart';
import '../api/media_item.dart';
import '../api/scan_result.dart';
import '../l10n/nsfw_localizations.dart';
import 'nsfw_result_badge.dart';
import 'theme/nsfw_design_tokens.dart';
import 'theme/nsfw_theme.dart';

/// Heads-up display for [NsfwCameraView] (Phase 04 / WIDGET-02).
///
/// Composes three layers — a top category pill, a confidence bar, and a
/// reused [NsfwResultBadge]. Lives as its own widget so it can be widget-
/// tested in isolation without spinning up the platform-view-backed
/// camera preview (WIDGET-08).
///
/// Reuse contract:
/// - [NsfwResultBadge] is reused **verbatim**. Camera frames are adapted to
///   a transient [ScanResult] via [_resultBadgeFromFrame] so the badge
///   keeps a single styling code path. **Do not** introduce a separate
///   `NsfwCameraBadge`.
/// - All colours, opacities and sizes flow through [NsfwGalleryTheme]
///   (extended with the four camera-only fields in WIDGET-07).
class NsfwCameraHud extends StatelessWidget {
  /// Latest camera-frame result. When null the HUD renders nothing — the
  /// caller should keep the widget mounted and pass the new result on each
  /// frame so [AnimatedSwitcher] can cross-fade smoothly.
  final CameraFrameResult? result;

  /// Theme used for category colours and HUD opacities. Falls back to
  /// [NsfwGalleryTheme.defaults] when not supplied.
  final NsfwGalleryTheme theme;

  /// Whether to show the [NsfwResultBadge] under the confidence bar.
  /// The top category pill and bar are always visible (when [result] is
  /// non-null) — the badge is the optional, more-detailed surface.
  final bool showConfidenceBadge;

  const NsfwCameraHud({
    super.key,
    required this.result,
    this.theme = NsfwGalleryTheme.defaults,
    this.showConfidenceBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 16,
          left: 16,
          right: 16,
          child: Align(
            alignment: Alignment.topCenter,
            child: _topCategoryPill(r),
          ),
        ),
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: _bottomBar(r),
        ),
      ],
    );
  }

  Widget _topCategoryPill(CameraFrameResult r) {
    final color = theme.categoryColor(r.topCategory.name);
    final l = NsfwLocalizations.current;
    final pct = (r.topConfidence * 100).toStringAsFixed(0);
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'NSFW live scan: ${r.topCategory.localizedName(l)}',
      value: '$pct%',
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: NsfwAnimations.standard.normal,
          child: Container(
            key: ValueKey('hud-pill-${r.topCategory.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: theme.cameraHudBackgroundOpacity),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              r.topCategory.displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                shadows: [
                  Shadow(blurRadius: 2, color: Colors.black54),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(CameraFrameResult r) {
    final color = theme.categoryColor(r.topCategory.name);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Live NSFW confidence',
          value: '${(r.topConfidence * 100).toStringAsFixed(0)}%',
          child: ExcludeSemantics(
            child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(theme.cameraConfidenceBarHeight),
              child: LinearProgressIndicator(
                value: r.topConfidence.clamp(0.0, 1.0),
                backgroundColor:
                    color.withValues(alpha: theme.cameraHudBackgroundOpacity),
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: theme.cameraConfidenceBarHeight,
              ),
            ),
          ),
        ),
        SizedBox(height: theme.cameraConfidenceBarHeight),
        if (showConfidenceBadge)
          NsfwResultBadge(
            result: _resultBadgeFromFrame(r),
            style: BadgeStyle.compact,
            theme: theme,
          ),
      ],
    );
  }

  /// Adapts a [CameraFrameResult] to a transient [ScanResult] so the existing
  /// [NsfwResultBadge] (designed for the gallery shape) renders without
  /// duplicating its styling. The synthetic `MediaItem` is empty — the badge
  /// only reads `labels` / `topCategory` / `topConfidence` / `status`.
  ScanResult _resultBadgeFromFrame(CameraFrameResult f) => ScanResult(
        item: MediaItem.empty(),
        labels: f.labels,
        detections: f.detections,
        status: ScanStatus.completed,
        confidenceThreshold: f.confidenceThreshold,
        scannedAt: f.frameTimestamp,
        fromCache: false,
      );
}
