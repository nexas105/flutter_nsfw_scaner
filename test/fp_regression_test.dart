// ignore_for_file: avoid_relative_lib_imports, prefer_const_constructors, no_leading_underscores_for_local_identifiers
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../tools/eval/lib/eval_dataset.dart';
import '../tools/eval/lib/fp_regression.dart';

void main() {
  group('runFpRegression — bucket tallying', () {
    test('counts FPs per subcategory and ignores non-safe items', () async {
      final ds = EvalDataset(items: const [
        // Two beach_photo items, one flagged as nudity → 1/2 = 50% FP rate.
        EvalItem(
          resolvedPath: 'b1',
          truth: NsfwCategory.safe,
          subcategory: 'beach_photo',
        ),
        EvalItem(
          resolvedPath: 'b2',
          truth: NsfwCategory.safe,
          subcategory: 'beach_photo',
        ),
        // One anime item, classified safe → 0/1 FP.
        EvalItem(
          resolvedPath: 'a1',
          truth: NsfwCategory.safe,
          subcategory: 'anime',
        ),
        // Non-safe item — must be skipped from FP tally.
        EvalItem(
          resolvedPath: 'n1',
          truth: NsfwCategory.nudity,
          subcategory: 'real_nsfw',
        ),
      ], skipped: const []);

      final report = await runFpRegression(
        dataset: ds,
        modelId: 'm',
        scan: (path) async {
          if (path == 'b1') {
            return ScanResult.fake(
              category: NsfwCategory.nudity,
              confidence: 0.9,
            );
          }
          return ScanResult.fake(category: NsfwCategory.safe);
        },
      );

      expect(report.totalSafeItems, 3, reason: 'nudity item excluded');
      expect(report.totalFalsePositives, 1);
      final beach = report.perSubcategory.firstWhere(
        (s) => s.subcategory == 'beach_photo',
      );
      expect(beach.total, 2);
      expect(beach.falsePositives, 1);
      expect(beach.rate, closeTo(0.5, 1e-9));
      final anime = report.perSubcategory.firstWhere(
        (s) => s.subcategory == 'anime',
      );
      expect(anime.falsePositives, 0);
      expect(anime.rate, 0.0);
    });

    test('uses "untagged" bucket when subcategory is null', () async {
      final ds = EvalDataset(items: const [
        EvalItem(resolvedPath: 'x', truth: NsfwCategory.safe),
      ], skipped: const []);

      final report = await runFpRegression(
        dataset: ds,
        modelId: 'm',
        scan: (_) async => ScanResult.fake(
          category: NsfwCategory.explicitNudity,
          confidence: 0.99,
        ),
      );
      expect(report.perSubcategory, hasLength(1));
      expect(report.perSubcategory.single.subcategory, 'untagged');
    });

    test('limits stored examples per bucket', () async {
      final ds = EvalDataset(
        items: List.generate(
          10,
          (i) => EvalItem(
            resolvedPath: 'item-$i',
            truth: NsfwCategory.safe,
            subcategory: 'beach_photo',
          ),
        ),
        skipped: const [],
      );
      final report = await runFpRegression(
        dataset: ds,
        modelId: 'm',
        scan: (_) async => ScanResult.fake(
          category: NsfwCategory.nudity,
          confidence: 0.99,
        ),
        examplesPerBucket: 2,
      );
      final beach = report.perSubcategory.single;
      expect(beach.falsePositives, 10);
      expect(beach.exampleFalsePositivePaths, hasLength(2));
    });
  });

  group('FpRegressionReport.exceeded', () {
    FpRegressionReport _build(double currentRate, double baselineRate) =>
        FpRegressionReport(
          modelId: 'm',
          perSubcategory: [
            SubcategoryFpRate(
              subcategory: 'beach_photo',
              total: 100,
              falsePositives: (currentRate * 100).round(),
              exampleFalsePositivePaths: const [],
            ),
          ],
          totalSafeItems: 100,
          totalFalsePositives: (currentRate * 100).round(),
          baseline: {'beach_photo': baselineRate},
          tolerance: 0.03,
        );

    test('flags a bucket that drifted > tolerance above baseline', () {
      final report = _build(0.10, 0.05);
      expect(report.exceeded, hasLength(1));
    });

    test('does not flag drift within tolerance', () {
      final report = _build(0.07, 0.05);
      expect(report.exceeded, isEmpty);
    });

    test('empty when no baseline is supplied', () {
      final report = FpRegressionReport(
        modelId: 'm',
        perSubcategory: const [
          SubcategoryFpRate(
            subcategory: 'x',
            total: 10,
            falsePositives: 9,
            exampleFalsePositivePaths: [],
          ),
        ],
        totalSafeItems: 10,
        totalFalsePositives: 9,
      );
      expect(report.exceeded, isEmpty);
    });
  });

  test('toMarkdown highlights exceeded buckets with a warning glyph', () {
    final report = FpRegressionReport(
      modelId: 'm',
      perSubcategory: const [
        SubcategoryFpRate(
          subcategory: 'beach_photo',
          total: 100,
          falsePositives: 12,
          exampleFalsePositivePaths: [],
        ),
      ],
      totalSafeItems: 100,
      totalFalsePositives: 12,
      baseline: const {'beach_photo': 0.04},
      tolerance: 0.03,
    );
    expect(report.toMarkdown(), contains('beach_photo'));
    expect(report.toMarkdown(), contains('⚠️'));
  });
}
