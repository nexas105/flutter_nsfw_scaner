# Privacy and Limitations

`nsfw_detect` is designed for local-first media analysis.

## Privacy behavior

- Inference runs on-device.
- Inference runs in the native iOS and Android layers.
- The plugin performs no analytics or telemetry network egress — it sends nothing about your media or scans to any server.
- Streamed scan results are delivered to your app.
- Picker-based scans can avoid full photo-library permission.
- `scanUrl` is the only Dart-initiated network call the plugin makes; everything else is local. Model downloads are explicit calls or the auto-download path your app opts into via `NsfwInitOptions.downloadIfMissing`.

Your app remains responsible for permission copy, privacy disclosures, moderation decisions, data retention, logging, and compliance with platform and legal requirements.

## `onTelemetryEvent` is a local callback

`NsfwDetector.onTelemetryEvent` (added in 2.4.0) is **not** network telemetry. It is a local Dart callback: the plugin hands structured `TelemetryEvent`s (scan timing, model id, top category, a `0..9` confidence decile) to your handler, and nothing leaves the device unless **you** choose to forward it.

- The event payload is PII-free by default. Raw confidence scores are suppressed into a decile bucket.
- An asset's `localId` is included only when you explicitly set `NsfwDetector.includeLocalIdsInTelemetry = true`.
- If you forward these events to an analytics backend, that egress — and its privacy disclosure — is your app's responsibility, not the plugin's.

Leaving `onTelemetryEvent` unset (the default) means no telemetry is produced at all. See the [cookbook](cookbook.md#wire-telemetry-hooks) for the handler shape.

## Recommended product language

Use language such as:

- "Checked on this device before sharing."
- "Flagged for review."
- "May contain sensitive content."
- "This automated check can make mistakes."

Avoid language such as:

- "Guaranteed safe."
- "Fully accurate."
- "This image is definitely explicit."
- "No review is ever needed."

## Probabilistic limitations

NSFW detection can produce false positives and false negatives. Accuracy can be affected by lighting, occlusion, cropping, unusual poses, illustrations, screenshots, compression, low resolution, sampled video frames, or ambiguous content.

`suggestive` is not treated as NSFW by `result.isNsfw`, but your product policy may still require a warning or review.

`unknown` usually means classification failed or output could not be mapped. Decide whether your app allows, blocks, retries, or reviews unknown results.

## Layered moderation

For higher-risk workflows, combine on-device detection with:

- User reporting
- Human review
- Additional policy checks
- Account reputation signals
- Policy-specific allow/block rules
- Rate limits and audit trails

On-device scanning is a strong privacy-preserving first pass, not a complete moderation system by itself.
