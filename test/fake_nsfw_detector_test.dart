// Pattern: copy this to your app's test dir.
//
// Demonstrates how a downstream app would unit-test a moderation-gate
// component using [FakeNsfwPlatform]. The fake replaces the real platform
// channel so no native binary is required — perfect for `dart test` /
// `flutter test` in CI.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
// ignore: implementation_imports
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

import '_fakes/fake_nsfw_detector.dart';

/// Hypothetical moderation gate: shows [child] when the scan is safe, a
/// "blocked" placeholder otherwise. A real app would render its own UI;
/// here we keep it minimal so the assertions speak to the behaviour, not
/// the visuals.
class _ExampleGate extends StatefulWidget {
  final String localId;
  final Widget child;
  const _ExampleGate({required this.localId, required this.child});

  @override
  State<_ExampleGate> createState() => _ExampleGateState();
}

class _ExampleGateState extends State<_ExampleGate> {
  ScanResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    try {
      final r = await NsfwDetector.instance.scanAsset(widget.localId);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Text('error', key: Key('error'));
    }
    if (_result == null) {
      return const Text('loading', key: Key('loading'));
    }
    if (_result!.isNsfw) {
      return const Text('blocked', key: Key('blocked'));
    }
    return widget.child;
  }
}

void main() {
  late FakeNsfwPlatform fake;

  setUp(() {
    fake = FakeNsfwPlatform();
    NsfwPlatformInterface.instance = fake;
  });

  tearDown(() {
    fake.dispose();
  });

  testWidgets('shows child when fake returns safe', (tester) async {
    fake.results['safe-1'] = ScanResult.fake(
      localIdentifier: 'safe-1',
      category: NsfwCategory.safe,
      confidence: 0.95,
    );

    await tester.pumpWidget(const MaterialApp(
      home: _ExampleGate(
        localId: 'safe-1',
        child: Text('child', key: Key('child')),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('child')), findsOneWidget);
    expect(find.byKey(const Key('blocked')), findsNothing);
    expect(
      fake.calls.where((c) => c.method == 'scanSingleAsset').length,
      1,
    );
  });

  testWidgets('blocks when fake returns explicit content', (tester) async {
    fake.results['nsfw-1'] = ScanResult.fake(
      localIdentifier: 'nsfw-1',
      category: NsfwCategory.explicitNudity,
      confidence: 0.92,
    );

    await tester.pumpWidget(const MaterialApp(
      home: _ExampleGate(
        localId: 'nsfw-1',
        child: Text('child', key: Key('child')),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('blocked')), findsOneWidget);
    expect(find.byKey(const Key('child')), findsNothing);
  });

  test('availableModels delegates to the fake registry', () async {
    final models = await NsfwDetector.instance.availableModels();
    expect(models, isNotEmpty);
    expect(models.first.id, ModelIds.openNsfw2);
  });

  test('captures every call for assertion', () async {
    await NsfwDetector.instance.checkPermission();
    await NsfwDetector.instance.scanAsset('abc');
    expect(
      fake.calls.map((c) => c.method),
      containsAll(['checkPermission', 'scanSingleAsset']),
    );
  });
}
