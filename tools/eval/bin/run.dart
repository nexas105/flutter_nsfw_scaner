import 'dart:convert';
import 'dart:io';

import 'package:nsfw_detect/nsfw_detect.dart';

// ignore_for_file: avoid_relative_lib_imports
import '../lib/eval_dataset.dart' show loadDataset;
import '../lib/eval_runner.dart' show runEval;

/// CLI entry: `dart run tools/eval/bin/run.dart <dataset.json> [--model id]
///                                              [--out report.json|.md]`
///
/// Loads a labelled dataset, runs every item through `NsfwDetector.scanFile`,
/// and writes a metrics report. Designed to be CI-callable on a host machine
/// with the example app's native binary installed; on plain `dart test`
/// hosts the harness lives in `test/eval_runner_test.dart` instead.
Future<void> main(List<String> argv) async {
  if (argv.isEmpty || argv.first == '-h' || argv.first == '--help') {
    stderr.writeln(
      'usage: dart run tools/eval/bin/run.dart <dataset.json> '
      '[--model <id>] [--out <path>] [--format json|md]',
    );
    exit(64);
  }

  final manifest = File(argv.first);
  if (!manifest.existsSync()) {
    stderr.writeln('dataset not found: ${manifest.path}');
    exit(66);
  }

  String modelId = ModelIds.openNsfw2;
  String format = 'md';
  String? outPath;
  for (var i = 1; i < argv.length; i++) {
    final arg = argv[i];
    final next = i + 1 < argv.length ? argv[i + 1] : null;
    switch (arg) {
      case '--model':
        if (next == null) {
          stderr.writeln('--model requires a value');
          exit(64);
        }
        modelId = next;
        i++;
      case '--out':
        if (next == null) {
          stderr.writeln('--out requires a value');
          exit(64);
        }
        outPath = next;
        i++;
      case '--format':
        if (next == null || (next != 'json' && next != 'md')) {
          stderr.writeln('--format expects json or md');
          exit(64);
        }
        format = next;
        i++;
      default:
        stderr.writeln('unknown argument: $arg');
        exit(64);
    }
  }

  final dataset = loadDataset(manifest);
  stdout.writeln(
    'Loaded ${dataset.items.length} items '
    '(${dataset.skipped.length} skipped) from ${manifest.path}',
  );
  for (final s in dataset.skipped) {
    stdout.writeln('  - row ${s.index}: ${s.reason}');
  }

  final report = await runEval(
    dataset: dataset,
    modelId: modelId,
    scan: (path) =>
        NsfwDetector.instance.scanFile(path, modelId: modelId),
    progress: (done, total) {
      if (done == total || done % 10 == 0) {
        stdout.writeln('  $done / $total');
      }
    },
  );

  final body = format == 'json'
      ? const JsonEncoder.withIndent('  ').convert(report.toJson())
      : report.toMarkdown();

  if (outPath != null) {
    File(outPath).writeAsStringSync(body);
    stdout.writeln('Wrote $outPath');
  } else {
    stdout.writeln();
    stdout.writeln(body);
  }
}
