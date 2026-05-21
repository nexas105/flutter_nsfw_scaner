import 'package:flutter/foundation.dart';

import 'scan_mode.dart';

/// Marks a `static const String` field (or a class) as a registered NSFW
/// model.
///
/// Pair with the `nsfw_detect_gen` builder (`dart run build_runner build`)
/// to emit a typed registry class — `_$<ClassName>Registry` — and a
/// `registerAll(NsfwDetector)` helper that calls `ensureReady` for every
/// annotated id.
///
/// Example:
///
/// ```dart
/// part 'my_models.g.dart';
///
/// class MyModels {
///   @NsfwModel(
///     id: 'opennsfw2_coreml',
///     defaultThreshold: 0.6,
///     displayName: 'OpenNSFW 2',
///     tags: {'classification', 'open-source'},
///   )
///   static const String openNsfw2 = 'opennsfw2_coreml';
/// }
/// ```
///
/// The annotation lives in the main `nsfw_detect` package; the generator is
/// an opt-in `dev_dependency` (`nsfw_detect_gen`) so apps that don't want a
/// build_runner step keep working unchanged.
@immutable
class NsfwModel {
  /// Stable model id sent across the method channel.
  final String id;

  /// Suggested confidence threshold for this model. Forwarded into the
  /// generated registry so callers can reference `MyModels.r.openNsfw2Threshold`.
  final double defaultThreshold;

  /// Default scan mode (`classification` vs `detection`).
  final ScanMode defaultMode;

  /// Optional human-readable label.
  final String? displayName;

  /// Free-form tag set — e.g. `{'classification', 'commercial-ok'}`.
  /// The generator emits the tag set unchanged so callers can filter at
  /// runtime.
  final Set<String> tags;

  const NsfwModel({
    required this.id,
    this.defaultThreshold = 0.7,
    this.defaultMode = ScanMode.classification,
    this.displayName,
    this.tags = const {},
  });
}
