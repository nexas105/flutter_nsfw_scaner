# Security Policy

`nsfw_detect` is designed for on-device media analysis and privacy-sensitive moderation workflows.

## Reporting a vulnerability

Please report security or privacy issues privately instead of opening a public issue.

Use GitHub's private vulnerability reporting if it is enabled for the repository. If it is not available, contact the maintainer through the repository profile and include:

- A concise description of the issue
- Affected package version
- Affected platform: iOS, Android, or both
- Reproduction steps or a minimal proof of concept
- Whether the issue can expose private media, scan results, file paths, permissions, or model downloads

Do not attach private or explicit media. Use synthetic or neutral test data whenever possible.

## Scope

Security-sensitive areas include:

- Media permission handling
- Camera and photo-library access
- File, bytes, picker, and library scanning paths
- Model download URLs and extraction
- Scan cache behavior
- Any change that could move media or scan results outside the device

## Supported versions

Security fixes should target the latest published version unless otherwise discussed in the issue.
