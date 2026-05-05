import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

/// Pure-Dart widget test for [NsfwCameraHud]. No platform-view backing —
/// we just construct a [CameraFrameResult] and verify that the HUD's
/// composition (top pill + confidence bar + reused [NsfwResultBadge])
/// renders correctly across categories and orientations.
void main() {
  Widget hostHud({
    required CameraFrameResult? result,
    bool showBadge = true,
    Size size = const Size(360, 800),
    NsfwGalleryTheme theme = NsfwGalleryTheme.defaults,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: NsfwCameraHud(
              result: result,
              theme: theme,
              showConfidenceBadge: showBadge,
            ),
          ),
        ),
      ),
    );
  }

  CameraFrameResult makeFrame({
    required NsfwCategory category,
    double confidence = 0.9,
    List<BodyPartDetection>? detections,
  }) =>
      CameraFrameResult(
        frameTimestamp: DateTime.fromMillisecondsSinceEpoch(0),
        labels: [NsfwLabel(category: category, confidence: confidence)],
        detections: detections,
      );

  testWidgets('renders nothing when result is null', (tester) async {
    await tester.pumpWidget(hostHud(result: null));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(NsfwResultBadge), findsNothing);
  });

  testWidgets('renders top category label, confidence bar, and badge',
      (tester) async {
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.nudity, confidence: 0.92),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(NsfwResultBadge), findsOneWidget);
    // Top pill renders the category displayName.
    expect(find.text(NsfwCategory.nudity.displayName), findsOneWidget);
  });

  testWidgets('hides badge when showConfidenceBadge=false', (tester) async {
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.safe, confidence: 0.99),
      showBadge: false,
    ));
    await tester.pumpAndSettle();

    expect(find.byType(NsfwResultBadge), findsNothing);
    // Bar is still there.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('confidence bar value reflects topConfidence', (tester) async {
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.suggestive, confidence: 0.42),
    ));
    await tester.pumpAndSettle();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.42, 0.0001));
  });

  testWidgets('lays out without overflow in landscape (800x360)',
      (tester) async {
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.nudity, confidence: 0.85),
      size: const Size(800, 360),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(NsfwCameraHud), findsOneWidget);
  });

  testWidgets('themed cameraConfidenceBarHeight propagates to bar minHeight',
      (tester) async {
    const theme = NsfwGalleryTheme(cameraConfidenceBarHeight: 12.0);
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.safe, confidence: 0.5),
      theme: theme,
    ));
    await tester.pumpAndSettle();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.minHeight, 12.0);
  });

  testWidgets('does not duplicate badge styling — adapts via private helper',
      (tester) async {
    // Verifies the reuse contract: HUD must contain exactly one
    // NsfwResultBadge, not a hand-rolled badge container.
    await tester.pumpWidget(hostHud(
      result: makeFrame(category: NsfwCategory.explicitNudity, confidence: 0.97),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(NsfwResultBadge), findsOneWidget);
  });
}
