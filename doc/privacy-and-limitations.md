# Privacy and Limitations

`nsfw_detect` is designed for local-first media analysis.

## Privacy behavior

- Inference runs on-device.
- Inference runs in the native iOS and Android layers.
- The plugin does not include analytics or telemetry.
- Streamed scan results are delivered to your app.
- Picker-based scans can avoid full photo-library permission.

Your app remains responsible for permission copy, privacy disclosures, moderation decisions, data retention, logging, and compliance with platform and legal requirements.

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
