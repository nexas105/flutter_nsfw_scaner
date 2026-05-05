import 'package:flutter/material.dart';
import 'nsfw_design_tokens.dart';

/// Legacy theme container for the gallery widgets. Still works as before, but
/// new widgets should consume [NsfwTheme] which carries a full token set.
/// `NsfwGalleryTheme` is preserved for backwards compatibility — every existing
/// constructor argument and field name is intact.
@immutable
class NsfwGalleryTheme {
  final Color safeColor;
  final Color suggestiveColor;
  final Color nsfwColor;
  final Color explicitColor;
  final Color pendingColor;
  final Color unknownColor;
  final TextStyle? badgeLabelStyle;
  final BorderRadius tileBorderRadius;
  final double badgeOpacity;
  final Color scaffoldBackgroundColor;
  final Color progressBarColor;
  final TextStyle? progressTextStyle;

  const NsfwGalleryTheme({
    this.safeColor = const Color(0xFF4CAF50),
    this.suggestiveColor = const Color(0xFFFF9800),
    this.nsfwColor = const Color(0xFFF44336),
    this.explicitColor = const Color(0xFF9C27B0),
    this.pendingColor = const Color(0xFF9E9E9E),
    this.unknownColor = const Color(0xFF607D8B),
    this.badgeLabelStyle,
    this.tileBorderRadius = const BorderRadius.all(Radius.circular(8)),
    this.badgeOpacity = 0.85,
    this.scaffoldBackgroundColor = Colors.black,
    this.progressBarColor = const Color(0xFF2196F3),
    this.progressTextStyle,
  });

  static const NsfwGalleryTheme defaults = NsfwGalleryTheme();

  Color categoryColor(String categoryName) => switch (categoryName) {
        'safe' => safeColor,
        'suggestive' => suggestiveColor,
        'nudity' => nsfwColor,
        'explicitNudity' => explicitColor,
        _ => unknownColor,
      };

  NsfwGalleryTheme copyWith({
    Color? safeColor,
    Color? suggestiveColor,
    Color? nsfwColor,
    Color? explicitColor,
    Color? pendingColor,
    Color? unknownColor,
    TextStyle? badgeLabelStyle,
    BorderRadius? tileBorderRadius,
    double? badgeOpacity,
    Color? scaffoldBackgroundColor,
    Color? progressBarColor,
    TextStyle? progressTextStyle,
  }) =>
      NsfwGalleryTheme(
        safeColor: safeColor ?? this.safeColor,
        suggestiveColor: suggestiveColor ?? this.suggestiveColor,
        nsfwColor: nsfwColor ?? this.nsfwColor,
        explicitColor: explicitColor ?? this.explicitColor,
        pendingColor: pendingColor ?? this.pendingColor,
        unknownColor: unknownColor ?? this.unknownColor,
        badgeLabelStyle: badgeLabelStyle ?? this.badgeLabelStyle,
        tileBorderRadius: tileBorderRadius ?? this.tileBorderRadius,
        badgeOpacity: badgeOpacity ?? this.badgeOpacity,
        scaffoldBackgroundColor:
            scaffoldBackgroundColor ?? this.scaffoldBackgroundColor,
        progressBarColor: progressBarColor ?? this.progressBarColor,
        progressTextStyle: progressTextStyle ?? this.progressTextStyle,
      );
}

/// Full design-token bundle consumed by the next-generation plugin widgets
/// (summary sheet, detail view, settings panel, picker button, skeleton tile,
/// etc.). Wraps the legacy [NsfwGalleryTheme] so every widget that already
/// accepts the legacy theme keeps working.
@immutable
class NsfwTheme {
  final Brightness brightness;
  final NsfwGalleryTheme gallery;
  final NsfwSpacing spacing;
  final NsfwTypography typography;
  final NsfwAnimations animations;
  final NsfwElevation elevation;

  // Semantic surface palette
  final Color surface;
  final Color surfaceVariant;
  final Color outline;
  final Color onSurface;
  final Color onSurfaceMuted;
  final Color accent;
  final Color danger;
  final Color success;

  const NsfwTheme({
    required this.brightness,
    required this.gallery,
    required this.spacing,
    required this.typography,
    required this.animations,
    required this.elevation,
    required this.surface,
    required this.surfaceVariant,
    required this.outline,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.accent,
    required this.danger,
    required this.success,
  });

  factory NsfwTheme.dark({
    NsfwGalleryTheme? gallery,
    Color? accent,
  }) {
    final palette = gallery ?? const NsfwGalleryTheme();
    return NsfwTheme(
      brightness: Brightness.dark,
      gallery: palette,
      spacing: NsfwSpacing.standard,
      typography: NsfwTypography.darkDefault(),
      animations: NsfwAnimations.standard,
      elevation: NsfwElevation.dark(),
      surface: const Color(0xFF1E1E1E),
      surfaceVariant: const Color(0xFF2A2A2A),
      outline: const Color(0x33FFFFFF),
      onSurface: Colors.white,
      onSurfaceMuted: const Color(0xFF9CA3AF),
      accent: accent ?? palette.progressBarColor,
      danger: const Color(0xFFEF4444),
      success: const Color(0xFF10B981),
    );
  }

  factory NsfwTheme.light({
    NsfwGalleryTheme? gallery,
    Color? accent,
  }) {
    final palette = gallery ??
        const NsfwGalleryTheme(
          scaffoldBackgroundColor: Color(0xFFF7F7F8),
        );
    return NsfwTheme(
      brightness: Brightness.light,
      gallery: palette,
      spacing: NsfwSpacing.standard,
      typography: NsfwTypography.lightDefault(),
      animations: NsfwAnimations.standard,
      elevation: NsfwElevation.light(),
      surface: Colors.white,
      surfaceVariant: const Color(0xFFF3F4F6),
      outline: const Color(0x1F000000),
      onSurface: const Color(0xFF111111),
      onSurfaceMuted: const Color(0xFF6B7280),
      accent: accent ?? palette.progressBarColor,
      danger: const Color(0xFFDC2626),
      success: const Color(0xFF059669),
    );
  }

  /// Default theme. Plugin defaults to dark because images render best on a
  /// neutral dark surface.
  static NsfwTheme defaults() => NsfwTheme.dark();

  NsfwTheme copyWith({
    NsfwGalleryTheme? gallery,
    NsfwSpacing? spacing,
    NsfwTypography? typography,
    NsfwAnimations? animations,
    NsfwElevation? elevation,
    Color? surface,
    Color? surfaceVariant,
    Color? outline,
    Color? onSurface,
    Color? onSurfaceMuted,
    Color? accent,
    Color? danger,
    Color? success,
  }) =>
      NsfwTheme(
        brightness: brightness,
        gallery: gallery ?? this.gallery,
        spacing: spacing ?? this.spacing,
        typography: typography ?? this.typography,
        animations: animations ?? this.animations,
        elevation: elevation ?? this.elevation,
        surface: surface ?? this.surface,
        surfaceVariant: surfaceVariant ?? this.surfaceVariant,
        outline: outline ?? this.outline,
        onSurface: onSurface ?? this.onSurface,
        onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
        accent: accent ?? this.accent,
        danger: danger ?? this.danger,
        success: success ?? this.success,
      );
}
