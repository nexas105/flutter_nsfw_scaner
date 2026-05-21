/// Scan mode determines which kind of ML pipeline runs natively for each asset.
///
/// * [classification] — Top-level NSFW category classifier (OpenNSFW2, Falconsai,
///   AdamCodd). Produces [NsfwLabel] entries on `ScanResult.labels`. This is the
///   default and is backwards-compatible with all pre-Phase-B integrations.
///
/// * [detection] — Bounding-box object detector (NudeNet-style body-part exposure).
///   Produces individual [BodyPartDetection] entries on `ScanResult.detections` AND
///   aggregates them into `ScanResult.labels` so existing badge / threshold UI
///   keeps working.
enum ScanMode {
  /// Classifier mode (default). Top-level NSFW categories per asset.
  classification('classification'),

  /// Detection mode. Bounding-box body-part detector (NudeNet).
  detection('detection'),

  /// Detect-then-classify pipeline. Runs the registered detector first,
  /// crops each emitted box, runs the registered NSFW *classifier* on every
  /// crop, and attaches the crop-level [NsfwLabel] list to each
  /// [BodyPartDetection]. Strictly stronger signal than classifier-only
  /// (per-region attribution) and detector-only (graded confidence per
  /// region) — at the cost of one extra classifier call per box.
  ///
  /// The detector picked from `ScanConfiguration.modelId` must be a detector
  /// kind; the classifier used for the second pass is the registered default
  /// classifier (currently OpenNSFW2). Configure both via
  /// `NsfwInitOptions.preloadModels` so the second-pass classifier is warm
  /// before the first detection lands.
  detectThenClassify('detectThenClassify');

  const ScanMode(this.wireValue);

  /// String value sent across the method channel and persisted in JSON.
  final String wireValue;

  /// Restores a [ScanMode] from its [wireValue]. Falls back to
  /// [ScanMode.classification] for unknown / null inputs so older configs
  /// stay BC.
  static ScanMode fromWire(String? value) {
    if (value == null) return ScanMode.classification;
    for (final m in ScanMode.values) {
      if (m.wireValue == value) return m;
    }
    return ScanMode.classification;
  }
}
