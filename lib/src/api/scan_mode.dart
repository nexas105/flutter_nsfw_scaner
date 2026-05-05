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
  detection('detection');

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
