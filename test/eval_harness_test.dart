// ignore_for_file: avoid_relative_lib_imports, prefer_const_constructors
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

import '../tools/eval/lib/eval_dataset.dart';
import '../tools/eval/lib/eval_metrics.dart';
import '../tools/eval/lib/eval_runner.dart';

void main() {
  group('tallyMetrics', () {
    test('perfect classifier yields F1 = 1 across observed categories', () {
      final pairs = <(NsfwCategory, NsfwCategory)>[
        (NsfwCategory.safe, NsfwCategory.safe),
        (NsfwCategory.safe, NsfwCategory.safe),
        (NsfwCategory.nudity, NsfwCategory.nudity),
        (NsfwCategory.explicitNudity, NsfwCategory.explicitNudity),
      ];
      final tally = tallyMetrics(pairs);
      for (final m in tally.perCategory) {
        if (m.support == 0) continue;
        expect(m.f1, 1.0, reason: '${m.category} should be perfect');
      }
    });

    test('confusion matrix counts each pair', () {
      final pairs = <(NsfwCategory, NsfwCategory)>[
        (NsfwCategory.nudity, NsfwCategory.safe),
        (NsfwCategory.nudity, NsfwCategory.safe),
        (NsfwCategory.nudity, NsfwCategory.nudity),
      ];
      final tally = tallyMetrics(pairs);
      expect(tally.confusion['nudity->safe'], 2);
      expect(tally.confusion['nudity->nudity'], 1);
    });

    test('per-category P / R / F1 — partial classifier', () {
      // Truth has 3 nudity, 2 safe. Predicted 2 of 3 nudity correctly,
      // 1 safe correctly + 1 safe-as-nudity.
      final pairs = <(NsfwCategory, NsfwCategory)>[
        (NsfwCategory.nudity, NsfwCategory.nudity),
        (NsfwCategory.nudity, NsfwCategory.nudity),
        (NsfwCategory.nudity, NsfwCategory.safe),
        (NsfwCategory.safe, NsfwCategory.safe),
        (NsfwCategory.safe, NsfwCategory.nudity),
      ];
      final tally = tallyMetrics(pairs);
      final nudity = tally.perCategory.firstWhere(
        (m) => m.category == NsfwCategory.nudity,
      );
      // nudity: TP=2, FP=1 (safe predicted as nudity), FN=1 (nudity-as-safe)
      expect(nudity.truePositive, 2);
      expect(nudity.falsePositive, 1);
      expect(nudity.falseNegative, 1);
      // precision = 2/3, recall = 2/3, f1 = 2/3
      expect(nudity.precision, closeTo(2 / 3, 1e-9));
      expect(nudity.recall, closeTo(2 / 3, 1e-9));
      expect(nudity.f1, closeTo(2 / 3, 1e-9));
    });
  });

  group('loadDataset', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('eval_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('parses well-formed manifest, resolves paths against directory', () {
      final manifest = File('${tmp.path}/manifest.json');
      manifest.writeAsStringSync('''
[
  {"path": "imgs/a.png", "truth": "safe"},
  {"path": "imgs/b.png", "truth": "nudity", "notes": "edge case"}
]
''');
      final ds = loadDataset(manifest);
      expect(ds.items, hasLength(2));
      expect(ds.skipped, isEmpty);
      expect(ds.items[0].resolvedPath, endsWith('imgs/a.png'));
      expect(ds.items[0].truth, NsfwCategory.safe);
      expect(ds.items[1].truth, NsfwCategory.nudity);
      expect(ds.items[1].notes, 'edge case');
    });

    test('skips malformed rows with reasons', () {
      final manifest = File('${tmp.path}/manifest.json');
      manifest.writeAsStringSync('''
[
  "not-an-object",
  {"truth": "safe"},
  {"path": "x.png"},
  {"path": "y.png", "truth": "bogus"},
  {"path": "z.png", "truth": "safe"}
]
''');
      final ds = loadDataset(manifest);
      expect(ds.items, hasLength(1));
      expect(ds.skipped, hasLength(4));
      expect(ds.skipped[0].reason, contains('not an object'));
      expect(ds.skipped[1].reason, contains('missing "path"'));
      expect(ds.skipped[2].reason, contains('missing "truth"'));
      expect(ds.skipped[3].reason, contains('unknown truth label'));
    });
  });

  group('runEval', () {
    test('counts errors when scan throws — categorises as unknown', () async {
      final dataset = EvalDataset(items: [
        const EvalItem(resolvedPath: 'a', truth: NsfwCategory.safe),
        const EvalItem(resolvedPath: 'b', truth: NsfwCategory.nudity),
      ], skipped: const []);

      final report = await runEval(
        dataset: dataset,
        modelId: 'fake-model',
        scan: (path) async {
          if (path == 'b') throw StateError('boom');
          return ScanResult.fake(category: NsfwCategory.safe);
        },
      );

      expect(report.errors, 1);
      expect(report.totalItems, 2);
      // (safe, safe), (nudity, unknown) — nudity predicted as unknown
      final nudity = report.perCategory.firstWhere(
        (m) => m.category == NsfwCategory.nudity,
      );
      expect(nudity.falseNegative, 1);
    });

    test('progress callback fires for every item', () async {
      final dataset = EvalDataset(items: List.generate(
        5,
        (i) => EvalItem(resolvedPath: 'p$i', truth: NsfwCategory.safe),
      ), skipped: const []);

      final progress = <(int, int)>[];
      await runEval(
        dataset: dataset,
        modelId: 'fake',
        scan: (_) async => ScanResult.fake(),
        progress: (done, total) => progress.add((done, total)),
      );

      expect(progress, hasLength(5));
      expect(progress.last, (5, 5));
    });
  });

  group('EvalReport rendering', () {
    test('toMarkdown writes a category table', () {
      final report = EvalReport(
        modelId: 'm',
        totalItems: 2,
        errors: 0,
        perCategory: const [
          CategoryMetrics(
            category: NsfwCategory.safe,
            truePositive: 1,
            falsePositive: 0,
            falseNegative: 1,
            support: 2,
          ),
        ],
        elapsed: const Duration(milliseconds: 42),
        confusion: const {'safe->safe': 1, 'safe->nudity': 1},
      );
      final md = report.toMarkdown();
      expect(md, contains('### Eval — m'));
      expect(md, contains('safe'));
      expect(md, contains('| 0.500 |'),
          reason: 'F1 = 0.500 for one TP and one FN');
    });

    test('macroF1 ignores zero-support categories', () {
      final report = EvalReport(
        modelId: 'm',
        totalItems: 1,
        errors: 0,
        perCategory: const [
          CategoryMetrics(
            category: NsfwCategory.safe,
            truePositive: 1,
            falsePositive: 0,
            falseNegative: 0,
            support: 1,
          ),
          CategoryMetrics(
            category: NsfwCategory.nudity,
            truePositive: 0,
            falsePositive: 0,
            falseNegative: 0,
            support: 0,
          ),
        ],
        elapsed: Duration.zero,
        confusion: const {},
      );
      expect(report.macroF1, 1.0);
    });
  });
}
