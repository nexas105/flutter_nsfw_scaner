import 'dart:convert';
import 'dart:io';

import 'package:nsfw_detect/nsfw_detect.dart';

/// One labelled fixture in an eval dataset.
class EvalItem {
  /// Absolute (or repo-relative) path to the image / video. Resolved against
  /// the dataset file's directory at load time.
  final String resolvedPath;

  /// Ground-truth NSFW category, parsed from the label string.
  final NsfwCategory truth;

  /// Optional free-form bucket used by the FP-regression suite to break
  /// false-positive rates down per "kind of edge case" (e.g.
  /// `beach_photo`, `art_nude`, `baby_bath`, `anime`).
  final String? subcategory;

  /// Optional notes preserved verbatim for the report.
  final String? notes;

  const EvalItem({
    required this.resolvedPath,
    required this.truth,
    this.subcategory,
    this.notes,
  });

  Map<String, Object?> toJson() => {
        'path': resolvedPath,
        'truth': truth.name,
        if (subcategory != null) 'subcategory': subcategory,
        if (notes != null) 'notes': notes,
      };
}

/// Result of loading a JSON dataset from disk. [skipped] surfaces lines the
/// loader rejected with a one-line reason so debugging a broken manifest
/// stays an honest exercise.
class EvalDataset {
  final List<EvalItem> items;
  final List<({int index, String reason})> skipped;

  const EvalDataset({required this.items, required this.skipped});
}

/// Loads a labelled dataset from a JSON file. The expected shape is a
/// top-level array of `{path, truth, notes?}` objects:
///
/// ```json
/// [
///   {"path": "fixtures/safe/cat.png", "truth": "safe"},
///   {"path": "fixtures/nsfw/x.png", "truth": "nudity", "notes": "edge case"}
/// ]
/// ```
///
/// Relative paths are resolved against the dataset file's directory.
/// Unknown labels and out-of-shape rows are skipped (with reasons).
EvalDataset loadDataset(File manifest) {
  final raw = manifest.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    throw FormatException(
      'Expected top-level JSON array in ${manifest.path}',
    );
  }
  final base = manifest.parent;
  final items = <EvalItem>[];
  final skipped = <({int index, String reason})>[];

  for (var i = 0; i < decoded.length; i++) {
    final entry = decoded[i];
    if (entry is! Map) {
      skipped.add((index: i, reason: 'row is not an object'));
      continue;
    }
    final path = entry['path'];
    final truth = entry['truth'];
    if (path is! String || path.isEmpty) {
      skipped.add((index: i, reason: 'missing "path"'));
      continue;
    }
    if (truth is! String) {
      skipped.add((index: i, reason: 'missing "truth"'));
      continue;
    }
    final category = NsfwCategory.values.firstWhere(
      (c) => c.name == truth,
      orElse: () => NsfwCategory.unknown,
    );
    if (category == NsfwCategory.unknown && truth != 'unknown') {
      skipped.add((index: i, reason: 'unknown truth label "$truth"'));
      continue;
    }
    final resolved = _resolvePath(base, path);
    items.add(EvalItem(
      resolvedPath: resolved,
      truth: category,
      subcategory: entry['subcategory'] as String?,
      notes: entry['notes'] as String?,
    ));
  }

  return EvalDataset(items: items, skipped: skipped);
}

String _resolvePath(Directory base, String rawPath) {
  if (rawPath.startsWith('/') || rawPath.startsWith(Platform.pathSeparator)) {
    return rawPath;
  }
  return File('${base.path}/$rawPath').absolute.path;
}
