// Smoke test for the `nsfw_detect_gen` builder output (#64).
//
// The generator lives in `gen/nsfw_detect_gen/` — a separate package that
// produces `_$<ClassName>Registry` classes from `@NsfwModel` annotations.
// We can't `import` that output directly from this package's `test/` tree,
// so we verify the contract structurally by checking:
//
//   1. The generated `.g.dart` file exists at the documented path.
//   2. The file contains the registry class declaration.
//   3. The file references every model id present in the source.
//
// Skips gracefully when the file is missing — the generator is opt-in and
// may not have run yet in CI.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const generatedPath =
      'gen/nsfw_detect_gen/example/lib/my_models.g.dart';
  const sourcePath = 'gen/nsfw_detect_gen/example/lib/my_models.dart';

  test('generated registry exists and matches the source annotations', () {
    final generated = File(generatedPath);
    if (!generated.existsSync()) {
      markTestSkipped(
        'Generated file $generatedPath not present — run '
        '`dart run build_runner build` in gen/nsfw_detect_gen/example/ '
        'to produce it.',
      );
      return;
    }

    final body = generated.readAsStringSync();
    expect(body, contains('_\$MyModelsRegistry'),
        reason: 'generator should emit the registry class');
    expect(body, contains('registerAll'),
        reason: 'generator should emit the ensureReady helper');

    final source = File(sourcePath);
    if (!source.existsSync()) {
      markTestSkipped(
        'Source file $sourcePath missing — generator output '
        'cannot be cross-checked.',
      );
      return;
    }
    final src = source.readAsStringSync();

    // Extract every `id: '...'` literal from the source annotations and
    // ensure each one appears in the generated registry.
    final idPattern = RegExp(r"id:\s*'([^']+)'");
    final ids = idPattern.allMatches(src).map((m) => m.group(1)!).toSet();
    expect(ids, isNotEmpty,
        reason: 'source must declare at least one @NsfwModel id');
    for (final id in ids) {
      expect(body, contains("'$id'"),
          reason: 'registry should surface id "$id"');
    }
  });
}
