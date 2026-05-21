import 'package:flutter/foundation.dart';

import 'scan_configuration.dart';

/// Options consumed by [NsfwDetector.init].
///
/// Wrap your splash / bootstrap flow around `await NsfwDetector.instance.init(...)`
/// to hide cold-start model load latency, push native logging into release
/// builds, and have a single canonical configuration entry point.
@immutable
class NsfwInitOptions {
  /// Models to preload. The first model is treated as the "primary" — if the
  /// list is empty, [ModelIds.openNsfw2] is preloaded.
  ///
  /// Preload happens sequentially so disk + memory pressure stay predictable.
  final List<String> preloadModels;

  /// Models that should be downloaded if they advertise `requiresDownload`
  /// and aren't already on disk. Use sparingly — downloads can be large.
  final List<String> downloadIfMissing;

  /// When true (default), [NsfwDetector.init] swallows model preload errors
  /// instead of throwing. The first real scan will retry naturally.
  ///
  /// Set to `false` for strict bootstraps where missing models must abort the
  /// app's launch.
  final bool tolerateModelErrors;

  /// Forwards to [NsfwDetector.setLogging]. Useful for capturing native
  /// inference logs during early development.
  final bool enableNativeLogging;

  /// Default confidence threshold returned by [NsfwInitOptions.defaultThreshold].
  /// Apps can centralise their tuning here and reuse it across the codebase.
  final double defaultThreshold;

  const NsfwInitOptions({
    this.preloadModels = const [ModelIds.openNsfw2],
    this.downloadIfMissing = const [],
    this.tolerateModelErrors = true,
    this.enableNativeLogging = false,
    this.defaultThreshold = 0.75,
  });

  /// Minimum-cost init — only registers the platform channel, preloads
  /// nothing. Useful when you want a `NsfwInitReport` for symmetry but don't
  /// need the model loaded yet.
  ///
  /// Intent: defer all model work to the first real scan. Best for apps that
  /// might never actually scan and want zero cold-start cost.
  const NsfwInitOptions.lazy()
      : preloadModels = const [],
        downloadIfMissing = const [],
        tolerateModelErrors = true,
        enableNativeLogging = false,
        defaultThreshold = 0.75;

  /// Development preset — preloads the default classifier, turns on native
  /// logging, and uses the standard threshold.
  ///
  /// Intent: maximise diagnostic visibility during development. Pair with
  /// `kDebugMode` to keep this off release builds. Use [NsfwInitOptions]
  /// directly for production tunings.
  const NsfwInitOptions.debug()
      : preloadModels = const [ModelIds.openNsfw2],
        downloadIfMissing = const [],
        tolerateModelErrors = true,
        enableNativeLogging = true,
        defaultThreshold = 0.75;

  /// Production preset — preloads the default classifier with logging off and
  /// uses the standard threshold. No automatic downloads.
  ///
  /// Intent: warm one model for predictable first-scan latency, keep the
  /// native side quiet, and let the app decide explicitly when (if ever) to
  /// download additional models. Recommended starting point for release
  /// builds.
  const NsfwInitOptions.production()
      : preloadModels = const [ModelIds.openNsfw2],
        downloadIfMissing = const [],
        tolerateModelErrors = true,
        enableNativeLogging = false,
        defaultThreshold = 0.75;
}

/// Aggregated result returned by [NsfwDetector.init].
///
/// Lets callers branch on real outcomes — "did preload succeed", "which
/// models failed" — without inspecting native logs.
@immutable
class NsfwInitReport {
  final List<String> preloaded;
  final List<String> downloaded;
  final Map<String, String> errors; // modelId → error message
  final Duration elapsed;

  const NsfwInitReport({
    required this.preloaded,
    required this.downloaded,
    required this.errors,
    required this.elapsed,
  });

  /// True when no model errored during init.
  bool get isHealthy => errors.isEmpty;

  @override
  String toString() => 'NsfwInitReport('
      'preloaded=${preloaded.length}, '
      'downloaded=${downloaded.length}, '
      'errors=${errors.length}, '
      'elapsed=${elapsed.inMilliseconds}ms)';
}
