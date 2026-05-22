// Golden tests for the widgets exported by the plugin (#36).
//
// Each widget renders inside a `RepaintBoundary` of fixed size with both the
// light and dark `NsfwTheme` variants. Goldens land under
// `test/widgets/goldens/` after running:
//
//     flutter test --update-goldens test/widgets/golden_test.dart
//
// Goldens are platform-sensitive; if you see drift on a different host /
// engine version, regenerate them rather than relaxing the comparator.
//
// Tagged `golden` so CI (Linux) can exclude them — goldens are generated and
// verified locally on macOS. Run `flutter test --exclude-tags golden` to
// reproduce the CI suite, or `flutter test test/widgets/golden_test.dart` to
// validate / regenerate goldens on the canonical host.
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

Widget _harness({
  required NsfwTheme theme,
  required Widget child,
  Size size = const Size(320, 80),
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: theme.brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: theme.accent,
        brightness: theme.brightness,
      ),
      scaffoldBackgroundColor: theme.gallery.scaffoldBackgroundColor,
    ),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _matches(
  WidgetTester tester,
  String name,
) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
  await expectLater(
    find.byType(RepaintBoundary).first,
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  final themes = {
    'light': NsfwTheme.light(),
    'dark': NsfwTheme.dark(),
  };

  // ──────────────────────────────────────────────────────────────────────
  // NsfwResultBadge — three category states (safe / suggestive / explicit).
  // ──────────────────────────────────────────────────────────────────────
  group('NsfwResultBadge', () {
    for (final entry in themes.entries) {
      final variant = entry.key;
      final theme = entry.value;

      testWidgets('safe — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          child: NsfwResultBadge(
            result: ScanResult.fake(
              category: NsfwCategory.safe,
              confidence: 0.95,
            ),
            style: BadgeStyle.detailed,
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'result_badge_safe_$variant');
      });

      testWidgets('suggestive — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          child: NsfwResultBadge(
            result: ScanResult.fake(
              category: NsfwCategory.suggestive,
              confidence: 0.78,
            ),
            style: BadgeStyle.detailed,
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'result_badge_suggestive_$variant');
      });

      testWidgets('explicit — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          child: NsfwResultBadge(
            result: ScanResult.fake(
              category: NsfwCategory.explicitNudity,
              confidence: 0.93,
            ),
            style: BadgeStyle.detailed,
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'result_badge_explicit_$variant');
      });
    }
  });

  // ──────────────────────────────────────────────────────────────────────
  // NsfwScanProgressBar — 0% / 50% / 100% snapshots via a synthetic stream.
  // ──────────────────────────────────────────────────────────────────────
  group('NsfwScanProgressBar', () {
    Stream<ScanProgress> single(ScanProgress p) async* {
      yield p;
    }

    for (final entry in themes.entries) {
      final variant = entry.key;
      final theme = entry.value;

      testWidgets('0% — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(320, 60),
          child: NsfwScanProgressBar(
            progressStream: single(const ScanProgress(
              scannedCount: 0,
              totalCount: 100,
              isComplete: false,
            )),
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'progress_bar_0_$variant');
      });

      testWidgets('50% — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(320, 60),
          child: NsfwScanProgressBar(
            progressStream: single(const ScanProgress(
              scannedCount: 50,
              totalCount: 100,
              isComplete: false,
            )),
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'progress_bar_50_$variant');
      });

      testWidgets('100% — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(320, 60),
          child: NsfwScanProgressBar(
            progressStream: single(const ScanProgress(
              scannedCount: 100,
              totalCount: 100,
              isComplete: true,
            )),
            theme: theme.gallery,
          ),
        ));
        await _matches(tester, 'progress_bar_100_$variant');
      });
    }
  });

  // ──────────────────────────────────────────────────────────────────────
  // NsfwSkeletonTile — animation explicitly NOT pumped to a frame deeper
  // than the first paint so the golden is deterministic across runs.
  // ──────────────────────────────────────────────────────────────────────
  group('NsfwSkeletonTile', () {
    for (final entry in themes.entries) {
      final variant = entry.key;
      final theme = entry.value;
      testWidgets('idle — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(120, 120),
          child: NsfwSkeletonTile(theme: theme),
        ));
        // Pump exactly one frame so the AnimationController initialises but
        // the curve sits at the begin value.
        await tester.pump();
        await expectLater(
          find.byType(RepaintBoundary).first,
          matchesGoldenFile('goldens/skeleton_tile_$variant.png'),
        );
      });
    }
  });

  // ──────────────────────────────────────────────────────────────────────
  // NsfwSelectionToolbar — empty + 3 selected.
  // ──────────────────────────────────────────────────────────────────────
  group('NsfwSelectionToolbar', () {
    final actions = <NsfwBulkAction>[
      NsfwBulkAction(
        label: 'Hide',
        icon: Icons.visibility_off_outlined,
        onInvoke: (_) {},
      ),
      NsfwBulkAction(
        label: 'Share',
        icon: Icons.share_outlined,
        onInvoke: (_) {},
      ),
    ];

    for (final entry in themes.entries) {
      final variant = entry.key;
      final theme = entry.value;

      testWidgets('empty — $variant', (tester) async {
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(480, 80),
          child: NsfwSelectionToolbar(
            selectedCount: 0,
            selectedResults: const [],
            actions: actions,
            onExit: () {},
            theme: theme,
          ),
        ));
        await _matches(tester, 'selection_toolbar_empty_$variant');
      });

      testWidgets('three selected — $variant', (tester) async {
        final results = List.generate(
          3,
          (i) => ScanResult.fake(
            localIdentifier: 'id-$i',
            category: NsfwCategory.nudity,
            confidence: 0.9,
          ),
        );
        await tester.pumpWidget(_harness(
          theme: theme,
          size: const Size(480, 80),
          child: NsfwSelectionToolbar(
            selectedCount: 3,
            selectedResults: results,
            actions: actions,
            onExit: () {},
            theme: theme,
          ),
        ));
        await _matches(tester, 'selection_toolbar_three_$variant');
      });
    }
  });
}
