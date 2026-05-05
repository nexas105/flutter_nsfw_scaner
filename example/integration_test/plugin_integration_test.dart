import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nsfw_detect/nsfw_detect.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
}
