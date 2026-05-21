# False Positives FAQ

> **NSFW detection is probabilistic.** Every classifier — including the ones in this plugin — produces false positives (safe content flagged as NSFW) and false negatives (NSFW content flagged as safe). This guide focuses on tuning the false-positive rate; the inverse trade-off applies to false negatives.

## "I get too many NSFW flags"

The single biggest knob is `confidenceThreshold`. The default in headless calls is 0.75. Raise it to flag fewer items.

```dart
// Stricter — flag only high-confidence matches
final result = await NsfwDetector.instance.scanFile(
  path,
  confidenceThreshold: 0.85,
);
```

Or use a preset:

```dart
const ScanConfiguration.strict()    // 0.85
const ScanConfiguration.moderate()  // 0.70 — default
const ScanConfiguration.permissive() // 0.50
```

### Threshold quick reference

The table below is **illustrative**, not benchmarked. Real false-positive rates depend heavily on your content distribution (selfies vs. art vs. screenshots vs. memes). Calibrate against a sample of your own data before locking in a value.

| Use case | Recommended threshold | Typical FP rate (illustrative) | Notes |
| --- | --- | --- | --- |
| Aggressive review queue | 0.50 | ~15% | Surface anything borderline; expect manual review. |
| Default user-content moderation | 0.70 | ~5% | Reasonable balance for most consumer apps. |
| Pre-publish hard gate | 0.85 | ~1% | Very few false positives; misses more edge cases. |
| Child-safety, high-stakes | 0.50 + human review | ~15% | Cast a wide net; route everything flagged to a reviewer. |

Numbers above are rough planning figures, not measurements from a benchmark. Run your own evaluation on a representative sample before relying on them in production.

## "Suggestive content gets flagged as NSFW"

`isNsfw` is true only for `nudity` and `explicitNudity` at or above the threshold. `suggestive` is not NSFW by default. If your app is treating it as NSFW, you are likely branching on `topCategory` instead:

```dart
// Branches on raw category — flags suggestive
if (result.topCategory != NsfwCategory.safe) { /* block */ }

// Uses the policy-aware boolean — does not flag suggestive
if (result.isNsfw) { /* block */ }
```

Use `result.isSuggestive` (added in 2.2) when you want a separate path for suggestive content.

## "Screenshots and memes get flagged"

Heavily compressed, low-resolution, or otherwise out-of-distribution images can confuse the classifier. Options:

- Use `ScanMode.detection` with the NudeNet detector model. Detection mode locates specific body parts, which is more robust to backgrounds and overlays than whole-image classification.
- Raise the threshold to 0.85.
- Compose your own policy: only block when `hasExplicitContent` is true, otherwise route to review.

## "Art and illustrations get flagged"

The bundled models are trained primarily on photographs. Illustrations, anime, and stylised art are out-of-distribution and produce noisier scores in both directions.

- Combine on-device detection with content-source rules (e.g. "skip scanning for posts tagged #art").
- Lower the impact of a single high-confidence flag by requiring multiple signals before taking action.

## "Per-frame camera flicker — same scene flips back and forth"

Camera detection is per-frame. A scene near the threshold will flip safe→NSFW→safe as small lighting changes nudge the confidence across the boundary. Mitigations:

- Use the built-in `NsfwCameraView` — its `AnimatedSwitcher` blur transitions hide single-frame jitter.
- Aggregate over a sliding window in your handler and only act on a sustained NSFW state (e.g. ≥ 3 of the last 5 frames).
- Reduce `fps`. At `fps: 2` you get more deliberate transitions than at `fps: 10`.

## "Detection mode misses partial coverage"

Detection mode reports per-class bounding boxes. If your product policy treats *covered* and *exposed* body parts differently, branch on the specific labels in `result.detections` rather than the top-level NSFW boolean. Lower `detectionConfidenceThreshold` (default 0.25) to surface lower-confidence boxes for review.

## When to escalate beyond the threshold

For high-risk surfaces, the threshold alone is not enough. Layer on:

- Human review for flagged content.
- User reporting and feedback loops.
- Per-account reputation signals.
- Policy-specific allow/block rules (e.g. "block any NSFW signal on accounts under 18").

On-device detection is a strong privacy-preserving first pass, not a complete moderation system on its own. See the [privacy and limitations guide](privacy-and-limitations.md) for product-language recommendations.
