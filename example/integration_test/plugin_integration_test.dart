import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ────────────────────────────────────────────────────────────────────────
  // Original Phase-1 smoke tests — kept verbatim per #35 ("ADD don't remove").
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('Permission check returns valid status', (tester) async {
    final detector = NsfwDetector.instance;
    final status = await detector.checkPermission();

    expect(
      status,
      isIn([
        PhotoLibraryPermissionStatus.authorized,
        PhotoLibraryPermissionStatus.limited,
        PhotoLibraryPermissionStatus.denied,
        PhotoLibraryPermissionStatus.restricted,
        PhotoLibraryPermissionStatus.notDetermined,
      ]),
    );
  });

  testWidgets('Available models returns non-empty list', (tester) async {
    final detector = NsfwDetector.instance;
    final models = await detector.availableModels();

    expect(models, isNotEmpty);
    expect(models.first.id, isNotEmpty);
    expect(models.first.displayName, isNotEmpty);
  });

  // ────────────────────────────────────────────────────────────────────────
  // #35 — real workflows.
  // ────────────────────────────────────────────────────────────────────────

  testWidgets('init() returns NsfwInitReport', (tester) async {
    final report = await NsfwDetector.instance.init(
      const NsfwInitOptions(
        preloadModels: [ModelIds.openNsfw2],
        enableNativeLogging: false,
      ),
    );
    expect(report, isA<NsfwInitReport>());
    expect(report.elapsed, greaterThanOrEqualTo(Duration.zero));
    // Either the model preloaded OR we got a recorded error — in both cases
    // init() must NOT throw with tolerateModelErrors=true (default).
    expect(report.preloaded.length + report.errors.length, greaterThan(0));
  });

  testWidgets('scanBytes returns ScanResult', (tester) async {
    // Load the bundled test image. The asset is registered in
    // example/pubspec.yaml under flutter.assets.
    final ByteData data = await rootBundle.load('assets/test/safe.png');
    final Uint8List bytes = data.buffer.asUint8List();

    final result = await NsfwDetector.instance.scanBytes(bytes);
    expect(result, isA<ScanResult>());
    expect(result.isNsfw, isFalse,
        reason: 'The bundled 1x1 white pixel cannot be NSFW.');
    expect(result.topConfidence, inInclusiveRange(0.0, 1.0));
  });

  // pickMedia (cancelled) — not testable without UI. We register the test
  // for documentation but skip it: it would otherwise drive the native
  // picker, which can't be cancelled programmatically from a headless
  // integration test. See README for a manual repro recipe.
  testWidgets('pickMedia (cancelled)', (tester) async {
    // Intentionally empty — placeholder for the manual-only workflow.
  }, skip: true);

  testWidgets('scanFiles batch progress', (tester) async {
    final ByteData data = await rootBundle.load('assets/test/safe.png');
    final Uint8List bytes = data.buffer.asUint8List();
    final tmp = Directory.systemTemp.createTempSync('nsfw_batch_');
    final a = File('${tmp.path}/batch_a.png')..writeAsBytesSync(bytes);
    final b = File('${tmp.path}/batch_b.png')..writeAsBytesSync(bytes);

    final progress = <(int, int)>[];
    final results = await NsfwDetector.instance.scanFiles(
      [a.path, b.path],
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(results.length, 2);
    expect(progress, isNotEmpty);
    expect(progress.first, (1, 2));
    expect(progress.last, (2, 2));

    // Cleanup.
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {/* not fatal */}
  });
}
