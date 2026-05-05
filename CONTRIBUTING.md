# Contributing

Thanks for helping improve `nsfw_detect`.

This package handles privacy-sensitive media workflows, so contributions should keep the API clear, predictable, and conservative. Avoid claims that detection is perfect or guaranteed; treat scan output as a probabilistic moderation signal.

## Good first contributions

- Documentation improvements
- Example app fixes
- Permission-flow edge cases
- Platform-specific troubleshooting notes
- Unit or widget tests for existing APIs
- Reproducible bug reports from real iOS or Android devices

## Before opening a pull request

Run:

```bash
dart format .
flutter test
dart pub publish --dry-run
```

For native changes, test on a real device when possible:

- iOS photo library and camera flows require the correct `Info.plist` permissions.
- Android media and camera flows depend on SDK version and manifest permissions.

## Pull request guidance

- Keep changes scoped to one behavior or documentation area.
- Include tests for Dart API or widget changes.
- Update `README.md`, `doc/`, or `CHANGELOG.md` when behavior or setup changes.
- Do not add explicit media samples to the repository.
- Do not introduce telemetry, analytics, or automatic media transmission without prior discussion.

For larger API, model, permission, or platform changes, open an issue first.
