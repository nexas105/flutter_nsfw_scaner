import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../api/nsfw_detector.dart';
import '../api/scan_result.dart';

/// Drop-in moderation gate. Scans the configured media source (bytes, file
/// path, or photo-library asset id) and decides whether to render [child] or
/// a blocked / blurred fallback.
///
/// Exactly one of [bytes], [filePath], or [localIdentifier] must be provided.
///
/// While the scan is in flight the gate shows [loading]; on platform failure
/// it shows [errorBuilder]'s output (defaults to rendering [child] —
/// fail-open). The default NSFW fallback is a blurred copy of [child] with a
/// short policy hint on top; override with [nsfwBuilder] for custom UI.
///
/// Results are reported through [onResult] for logging / analytics.
class NsfwModerationGate extends StatefulWidget {
  final Uint8List? bytes;
  final String? filePath;
  final String? localIdentifier;

  /// The "safe" content. Rendered as-is when the scan completes and is not NSFW.
  final Widget child;

  /// Built when the scan is in flight. Defaults to a small centered
  /// `CircularProgressIndicator`.
  final Widget? loading;

  /// Builder used when the result is NSFW. Defaults to a blur + warning
  /// overlay on top of [child].
  final Widget Function(BuildContext context, ScanResult result, Widget child)?
      nsfwBuilder;

  /// Builder used when the scan throws. Defaults to rendering [child]
  /// (fail-open). Pass a stricter builder to fail-closed.
  final Widget Function(BuildContext context, Object error, Widget child)?
      errorBuilder;

  /// Optional callback fired once the scan completes.
  final void Function(ScanResult result)? onResult;

  /// Optional model override.
  final String? modelId;

  /// Threshold used for `result.isNsfw`. Defaults to 0.7.
  final double confidenceThreshold;

  /// Optional lower bound for the "uncertain" zone. When set, a result
  /// whose `topConfidence` falls into `[confidenceFloor, confidenceThreshold)`
  /// is treated as uncertain — [uncertainBuilder] is rendered instead of
  /// either pass or block. Useful for moderation UIs that want a
  /// manual-review affordance instead of a hard binary verdict.
  ///
  /// Must be `< confidenceThreshold`. `null` disables the band (old
  /// pass/block behaviour).
  final double? confidenceFloor;

  /// Builder used when the result falls into the uncertainty band defined
  /// by [confidenceFloor]. Defaults to a softer overlay (no blur, warning
  /// pill). Ignored when [confidenceFloor] is null.
  final Widget Function(BuildContext context, ScanResult result, Widget child)?
      uncertainBuilder;

  const NsfwModerationGate({
    super.key,
    required this.child,
    this.bytes,
    this.filePath,
    this.localIdentifier,
    this.loading,
    this.nsfwBuilder,
    this.errorBuilder,
    this.onResult,
    this.modelId,
    this.confidenceThreshold = 0.7,
    this.confidenceFloor,
    this.uncertainBuilder,
  })  : assert(
          (bytes != null ? 1 : 0) +
                  (filePath != null ? 1 : 0) +
                  (localIdentifier != null ? 1 : 0) ==
              1,
          'NsfwModerationGate requires exactly one of bytes, filePath, or localIdentifier.',
        ),
        assert(
          confidenceFloor == null || confidenceFloor < confidenceThreshold,
          'confidenceFloor must be strictly below confidenceThreshold.',
        );

  /// Construct from raw image bytes.
  const NsfwModerationGate.bytes(
    Uint8List bytes, {
    Key? key,
    required Widget child,
    Widget? loading,
    Widget Function(BuildContext, ScanResult, Widget)? nsfwBuilder,
    Widget Function(BuildContext, Object, Widget)? errorBuilder,
    void Function(ScanResult)? onResult,
    String? modelId,
    double confidenceThreshold = 0.7,
    double? confidenceFloor,
    Widget Function(BuildContext, ScanResult, Widget)? uncertainBuilder,
  }) : this(
          key: key,
          bytes: bytes,
          child: child,
          loading: loading,
          nsfwBuilder: nsfwBuilder,
          errorBuilder: errorBuilder,
          onResult: onResult,
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          confidenceFloor: confidenceFloor,
          uncertainBuilder: uncertainBuilder,
        );

  /// Construct from a local file path.
  const NsfwModerationGate.file(
    String filePath, {
    Key? key,
    required Widget child,
    Widget? loading,
    Widget Function(BuildContext, ScanResult, Widget)? nsfwBuilder,
    Widget Function(BuildContext, Object, Widget)? errorBuilder,
    void Function(ScanResult)? onResult,
    String? modelId,
    double confidenceThreshold = 0.7,
    double? confidenceFloor,
    Widget Function(BuildContext, ScanResult, Widget)? uncertainBuilder,
  }) : this(
          key: key,
          filePath: filePath,
          child: child,
          loading: loading,
          nsfwBuilder: nsfwBuilder,
          errorBuilder: errorBuilder,
          onResult: onResult,
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          confidenceFloor: confidenceFloor,
          uncertainBuilder: uncertainBuilder,
        );

  /// Construct from a photo-library asset local id.
  const NsfwModerationGate.asset(
    String localIdentifier, {
    Key? key,
    required Widget child,
    Widget? loading,
    Widget Function(BuildContext, ScanResult, Widget)? nsfwBuilder,
    Widget Function(BuildContext, Object, Widget)? errorBuilder,
    void Function(ScanResult)? onResult,
    String? modelId,
    double confidenceThreshold = 0.7,
    double? confidenceFloor,
    Widget Function(BuildContext, ScanResult, Widget)? uncertainBuilder,
  }) : this(
          key: key,
          localIdentifier: localIdentifier,
          child: child,
          loading: loading,
          nsfwBuilder: nsfwBuilder,
          errorBuilder: errorBuilder,
          onResult: onResult,
          modelId: modelId,
          confidenceThreshold: confidenceThreshold,
          confidenceFloor: confidenceFloor,
          uncertainBuilder: uncertainBuilder,
        );

  @override
  State<NsfwModerationGate> createState() => _NsfwModerationGateState();
}

class _NsfwModerationGateState extends State<NsfwModerationGate> {
  late Future<ScanResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _runScan();
  }

  @override
  void didUpdateWidget(covariant NsfwModerationGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sourceChanged(oldWidget)) {
      _future = _runScan();
    }
  }

  bool _sourceChanged(NsfwModerationGate o) {
    if (!identical(widget.bytes, o.bytes)) return true;
    if (widget.filePath != o.filePath) return true;
    if (widget.localIdentifier != o.localIdentifier) return true;
    if (widget.modelId != o.modelId) return true;
    if (widget.confidenceThreshold != o.confidenceThreshold) return true;
    if (widget.confidenceFloor != o.confidenceFloor) return true;
    return false;
  }

  Future<ScanResult> _runScan() async {
    final detector = NsfwDetector.instance;
    late ScanResult result;
    if (widget.bytes != null) {
      result = await detector.scanBytes(
        widget.bytes!,
        modelId: widget.modelId,
        confidenceThreshold: widget.confidenceThreshold,
      );
    } else if (widget.filePath != null) {
      result = await detector.scanFile(
        widget.filePath!,
        modelId: widget.modelId,
        confidenceThreshold: widget.confidenceThreshold,
      );
    } else {
      result = await detector.scanAsset(
        widget.localIdentifier!,
        modelId: widget.modelId,
        confidenceThreshold: widget.confidenceThreshold,
      );
    }
    widget.onResult?.call(result);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ScanResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loading ?? _defaultLoading();
        }
        if (snapshot.hasError) {
          final builder = widget.errorBuilder ?? _defaultErrorFallback;
          return builder(context, snapshot.error!, widget.child);
        }
        final result = snapshot.data!;
        if (result.isNsfw) {
          final builder = widget.nsfwBuilder ?? _defaultBlur;
          return builder(context, result, widget.child);
        }
        // Uncertainty band — only when the caller asked for one. We re-test
        // against the result's labels rather than result.topConfidence so
        // results from detector-kind models (where topConfidence may be the
        // safe-bucket confidence) still trip the band on their NSFW labels.
        final floor = widget.confidenceFloor;
        if (floor != null && _inUncertainBand(result, floor, widget.confidenceThreshold)) {
          final builder = widget.uncertainBuilder ?? _defaultUncertain;
          return builder(context, result, widget.child);
        }
        return widget.child;
      },
    );
  }

  static bool _inUncertainBand(ScanResult result, double floor, double threshold) {
    // Look at the highest-confidence NSFW-bearing label; "safe" labels never
    // count toward the band. Mirrors how ScanResult.isNsfw walks the label
    // list rather than reading topConfidence directly.
    double maxNsfwConfidence = 0;
    for (final label in result.labels) {
      if (label.category.isNsfw && label.confidence > maxNsfwConfidence) {
        maxNsfwConfidence = label.confidence;
      }
    }
    return maxNsfwConfidence >= floor && maxNsfwConfidence < threshold;
  }

  Widget _defaultLoading() => const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );

  Widget _defaultErrorFallback(BuildContext _, Object __, Widget child) =>
      child;

  static const Color _overlay = Color(0x73000000); // black 45%
  static const Color _pill = Color(0x8C000000); // black 55%
  static const Color _uncertainPill = Color(0xCCFFA000); // amber 80%

  /// Default uncertain-band overlay — a small amber pill on top of the
  /// un-blurred child. Avoids the heavy blur so moderators can still read
  /// the content but still see a clear signal.
  Widget _defaultUncertain(BuildContext context, ScanResult _, Widget child) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        const Positioned(
          top: 8,
          right: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _uncertainPill,
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                'Review recommended',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _defaultBlur(BuildContext context, ScanResult _, Widget child) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: child,
        ),
        const Positioned.fill(
          child: ColoredBox(
            color: _overlay,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _pill,
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Text(
                      'Content hidden — possibly explicit',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
