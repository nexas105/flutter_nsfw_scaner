/// User override applied to a scan result.
///
/// Stored in [DecisionStore] keyed by an asset's `localIdentifier` so the
/// detector can keep producing model output while UI / business code
/// remembers the moderator's verdict across sessions.
enum ScanDecision {
  /// Moderator explicitly allowed the asset — UI should render it even if
  /// the classifier still flags it as NSFW.
  allow,

  /// Moderator explicitly blocked the asset — UI should treat it as
  /// blocked regardless of the current classifier output.
  block,

  /// No override (or override cleared). Treated as "fall back to the model
  /// score". `mark(...)` with `ScanDecision.reset` removes the entry.
  reset;

  /// Wire-stable serialised form for persistence backends.
  String get wireValue => name;

  /// Parses a wire value. Unknown / missing input → `null`.
  static ScanDecision? fromWire(String? raw) {
    if (raw == null) return null;
    for (final d in ScanDecision.values) {
      if (d.wireValue == raw) return d;
    }
    return null;
  }
}
