import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsfw_detect/src/platform/nsfw_method_channel.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';
import 'package:nsfw_detect/src/api/scan_configuration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = NsfwMethodChannel();
  const methodChannel = MethodChannel('nsfw_detect_ios/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      switch (call.method) {
        case 'requestPermission':
          return 'authorized';
        case 'checkPermission':
          return 'limited';
        case 'availableModels':
          return [
            {
              'id': 'opennsfw2_coreml',
              'displayName': 'OpenNSFW2',
              'metadata': <String, dynamic>{},
            }
          ];
        case 'preloadModel':
          return null;
        case 'startScan':
          return null;
        case 'cancelScan':
          return null;
        case 'resetScan':
          return null;
        case 'scanSingleAsset':
          return {
            'localId': call.arguments['localId'],
            'mediaType': 'image',
            'status': 'completed',
            'scannedAt': 1700000000000,
            'labels': [
              {'category': 'safe', 'confidence': 0.9},
            ],
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('requestPermission returns correct status', () async {
    final status = await platform.requestPermission();
    expect(status, PhotoLibraryPermissionStatus.authorized);
  });

  test('checkPermission returns correct status', () async {
    final status = await platform.checkPermission();
    expect(status, PhotoLibraryPermissionStatus.limited);
  });

  test('availableModels returns parsed descriptors', () async {
    final models = await platform.availableModels();
    expect(models, hasLength(1));
    expect(models.first.id, 'opennsfw2_coreml');
    expect(models.first.displayName, 'OpenNSFW2');
  });

  test('startScan does not throw', () async {
    await expectLater(
      platform.startScan(const ScanConfiguration()),
      completes,
    );
  });

  test('cancelScan does not throw', () async {
    await expectLater(platform.cancelScan(), completes);
  });

  test('resetScan does not throw', () async {
    await expectLater(platform.resetScan(), completes);
  });

  test('scanSingleAsset returns map with localId', () async {
    final result = await platform.scanSingleAsset('photo-abc');
    expect(result['localId'], 'photo-abc');
    expect(result['status'], 'completed');
  });
}
