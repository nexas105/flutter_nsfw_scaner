import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect_ios_example/main.dart';
import 'package:nsfw_detect_ios_example/state/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();

    await tester.pumpWidget(NsfwDetectExampleApp(settings: settings));
    await tester.pumpAndSettle();

    // Verify the settings button exists in the gallery tab.
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
  });
}
