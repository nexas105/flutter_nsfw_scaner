import 'package:flutter/material.dart';

/// Spacing scale used across the plugin's widgets. The numbers are powers-of-2
/// up to 16, then jumps of 8. Pass these to `Padding`, `SizedBox`, `gap` etc.
@immutable
class NsfwSpacing {
  final double xxs;
  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;
  final double xxl;

  const NsfwSpacing({
    this.xxs = 2,
    this.xs = 4,
    this.sm = 8,
    this.md = 12,
    this.lg = 16,
    this.xl = 24,
    this.xxl = 32,
  });

  static const NsfwSpacing standard = NsfwSpacing();
}

/// Typography ramp. Each role is nullable so callers can pull from
/// `Theme.of(context).textTheme` and only override the slots they need.
@immutable
class NsfwTypography {
  final TextStyle display;
  final TextStyle title;
  final TextStyle body;
  final TextStyle caption;
  final TextStyle mono;
  final TextStyle label;

  const NsfwTypography({
    required this.display,
    required this.title,
    required this.body,
    required this.caption,
    required this.mono,
    required this.label,
  });

  factory NsfwTypography.darkDefault() => const NsfwTypography(
        display: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.2,
        ),
        title: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.3,
        ),
        body: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: Color(0xFFE6E6E6),
          height: 1.4,
        ),
        caption: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Color(0xFF9CA3AF),
          height: 1.3,
        ),
        mono: TextStyle(
          fontSize: 12,
          fontFamily: 'Courier',
          color: Color(0xFFC8C8C8),
          height: 1.3,
        ),
        label: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFF9CA3AF),
          letterSpacing: 1.2,
        ),
      );

  factory NsfwTypography.lightDefault() => const NsfwTypography(
        display: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: Color(0xFF111111),
          height: 1.2,
        ),
        title: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Color(0xFF111111),
          height: 1.3,
        ),
        body: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: Color(0xFF1F2937),
          height: 1.4,
        ),
        caption: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Color(0xFF6B7280),
          height: 1.3,
        ),
        mono: TextStyle(
          fontSize: 12,
          fontFamily: 'Courier',
          color: Color(0xFF374151),
          height: 1.3,
        ),
        label: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Color(0xFF6B7280),
          letterSpacing: 1.2,
        ),
      );

  NsfwTypography copyWith({
    TextStyle? display,
    TextStyle? title,
    TextStyle? body,
    TextStyle? caption,
    TextStyle? mono,
    TextStyle? label,
  }) =>
      NsfwTypography(
        display: display ?? this.display,
        title: title ?? this.title,
        body: body ?? this.body,
        caption: caption ?? this.caption,
        mono: mono ?? this.mono,
        label: label ?? this.label,
      );
}

/// Animation curve / duration tokens. Use the named values rather than
/// hard-coding milliseconds so the plugin can tune motion globally.
@immutable
class NsfwAnimations {
  final Duration fast;
  final Duration normal;
  final Duration slow;
  final Curve curve;

  const NsfwAnimations({
    this.fast = const Duration(milliseconds: 150),
    this.normal = const Duration(milliseconds: 250),
    this.slow = const Duration(milliseconds: 400),
    this.curve = Curves.easeOutCubic,
  });

  static const NsfwAnimations standard = NsfwAnimations();
}

/// Elevation / shadow tokens.
@immutable
class NsfwElevation {
  final List<BoxShadow> low;
  final List<BoxShadow> mid;
  final List<BoxShadow> high;

  const NsfwElevation({required this.low, required this.mid, required this.high});

  factory NsfwElevation.dark() => const NsfwElevation(
        low: [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
        mid: [BoxShadow(color: Color(0x55000000), blurRadius: 10, offset: Offset(0, 4))],
        high: [BoxShadow(color: Color(0x88000000), blurRadius: 24, offset: Offset(0, 12))],
      );

  factory NsfwElevation.light() => const NsfwElevation(
        low: [BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 1))],
        mid: [BoxShadow(color: Color(0x1F000000), blurRadius: 10, offset: Offset(0, 4))],
        high: [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 12))],
      );
}
