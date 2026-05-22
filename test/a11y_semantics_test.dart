import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  group('NsfwResultBadge semantics', () {
    testWidgets('announces category + confidence as one node', (tester) async {
      final result = ScanResult.fake(
        category: NsfwCategory.explicitNudity,
        confidence: 0.87,
      );
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NsfwResultBadge(result: result)),
      ));
      final node = tester.getSemantics(find.byType(NsfwResultBadge));
      expect(node, matchesSemantics(
        label: 'NSFW: Explicit Nudity',
        value: '87%',
      ));
      handle.dispose();
    });

    testWidgets('pending state announces scanning, no quantitative value',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: NsfwResultBadge()),
      ));
      final node = tester.getSemantics(find.byType(NsfwResultBadge));
      expect(node.label, contains('NSFW:'));
      expect(node.value, isEmpty,
          reason: 'pending state has no quantitative value');
      handle.dispose();
    });

    testWidgets('failed and skipped status get distinct labels',
        (tester) async {
      final handle = tester.ensureSemantics();
      final failed = ScanResult.fake(status: ScanStatus.failed);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NsfwResultBadge(result: failed)),
      ));
      expect(tester.getSemantics(find.byType(NsfwResultBadge)).label,
          'NSFW: scan failed');

      final skipped = ScanResult.fake(status: ScanStatus.skipped);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: NsfwResultBadge(result: skipped)),
      ));
      expect(tester.getSemantics(find.byType(NsfwResultBadge)).label,
          'NSFW: scan skipped');
      handle.dispose();
    });
  });

  group('NsfwMediaTile semantics', () {
    testWidgets('tile announces type + category + confidence and is a button',
        (tester) async {
      final handle = tester.ensureSemantics();
      final result = ScanResult.fake(
        localIdentifier: 'tile-1',
        category: NsfwCategory.nudity,
        confidence: 0.91,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: NsfwMediaTile(
              item: result.item,
              result: result,
              onTap: () {},
            ),
          ),
        ),
      ));
      final node = tester.getSemantics(find.byType(NsfwMediaTile));
      expect(node.label, contains('Photo'));
      expect(node.label, contains('Nudity'));
      expect(node.value, '91%');
      expect(
        node.getSemanticsData().flagsCollection.isButton,
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('video tile labels itself as Video', (tester) async {
      final handle = tester.ensureSemantics();
      final result = ScanResult.fake(
        type: MediaType.video,
        category: NsfwCategory.safe,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: NsfwMediaTile(item: result.item, result: result),
          ),
        ),
      ));
      expect(
        tester.getSemantics(find.byType(NsfwMediaTile)).label,
        contains('Video'),
      );
      handle.dispose();
    });

    testWidgets('label is fully localized under a non-English bundle',
        (tester) async {
      NsfwLocalizations.current = const NsfwLocalizationsDe();
      addTearDown(
          () => NsfwLocalizations.current = const NsfwLocalizationsEn());
      final handle = tester.ensureSemantics();
      final result = ScanResult.fake(
        category: NsfwCategory.nudity,
        confidence: 0.91,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: NsfwMediaTile(item: result.item, result: result),
          ),
        ),
      ));
      // Media-kind word and category both come from the German bundle —
      // no mixed-language fragments ("Foto, Nacktheit", not "Photo, …").
      expect(
        tester.getSemantics(find.byType(NsfwMediaTile)).label,
        'Foto, Nacktheit',
      );
      handle.dispose();
    });
  });

  group('NsfwCameraHud semantics', () {
    testWidgets('top pill exposes a live region', (tester) async {
      final handle = tester.ensureSemantics();
      final frame = CameraFrameResult(
        frameTimestamp: DateTime.now(),
        labels: const [
          NsfwLabel(category: NsfwCategory.nudity, confidence: 0.72),
        ],
        confidenceThreshold: 0.7,
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: NsfwCameraHud(result: frame),
          ),
        ),
      ));
      final node = tester.firstWidget<Semantics>(
        find.descendant(
          of: find.byType(NsfwCameraHud),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics &&
                (w.properties.label ?? '').startsWith('NSFW live scan'),
          ),
        ),
      );
      expect(node.properties.label, 'NSFW live scan: Nudity');
      expect(node.properties.value, '72%');
      expect(node.properties.liveRegion, isTrue);
      handle.dispose();
    });
  });
}
