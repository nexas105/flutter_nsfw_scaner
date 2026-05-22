// Contrast audit for NsfwGalleryTheme — pins WCAG 2.1 AA compliance for badge
// text/icons against every category colour. Follow-up to the v2.5.1 a11y pass,
// which deferred the programmatic contrast check.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  // AA threshold for normal text (badge labels are ~11px w600 — not "large").
  const aaNormal = 4.5;

  group('contrastRatio', () {
    test('black vs white is the maximum 21:1', () {
      expect(
        NsfwGalleryTheme.contrastRatio(
            const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21.0, 0.01),
      );
    });

    test('identical colours are 1:1', () {
      expect(
        NsfwGalleryTheme.contrastRatio(
            const Color(0xFF4CAF50), const Color(0xFF4CAF50)),
        closeTo(1.0, 0.001),
      );
    });

    test('is symmetric', () {
      const a = Color(0xFFFF9800);
      const b = Color(0xFF1E1E1E);
      expect(
        NsfwGalleryTheme.contrastRatio(a, b),
        closeTo(NsfwGalleryTheme.contrastRatio(b, a), 0.0001),
      );
    });
  });

  group('readableForeground — default category colours meet AA', () {
    const theme = NsfwGalleryTheme.defaults;
    final cases = <String, Color>{
      'safe': theme.safeColor,
      'suggestive': theme.suggestiveColor,
      'nudity': theme.nsfwColor,
      'explicitNudity': theme.explicitColor,
      'pending': theme.pendingColor,
      'unknown': theme.unknownColor,
    };

    for (final entry in cases.entries) {
      test('${entry.key} badge fill passes AA (≥ $aaNormal:1)', () {
        final fg = NsfwGalleryTheme.readableForeground(entry.value);
        final ratio = NsfwGalleryTheme.contrastRatio(entry.value, fg);
        expect(
          ratio,
          greaterThanOrEqualTo(aaNormal),
          reason: '${entry.key} (${entry.value}) → fg $fg only $ratio:1',
        );
      });
    }

    test('onCategoryColor matches readableForeground', () {
      for (final name in ['safe', 'suggestive', 'nudity', 'explicitNudity']) {
        expect(
          theme.onCategoryColor(name),
          NsfwGalleryTheme.readableForeground(theme.categoryColor(name)),
        );
      }
    });
  });

  test('readableForeground yields AA for any opaque colour (sweep)', () {
    // The better of black/white against an opaque background is always
    // ≥ ~4.54:1 — verify the invariant so custom themes stay safe too.
    for (var r = 0; r < 256; r += 17) {
      for (var g = 0; g < 256; g += 17) {
        for (var b = 0; b < 256; b += 17) {
          final bg = Color.fromARGB(255, r, g, b);
          final fg = NsfwGalleryTheme.readableForeground(bg);
          expect(
            NsfwGalleryTheme.contrastRatio(bg, fg),
            greaterThanOrEqualTo(aaNormal),
            reason: 'failed for $bg',
          );
        }
      }
    }
  });
}
