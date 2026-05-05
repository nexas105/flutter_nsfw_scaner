import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:nsfw_detect/src/platform/nsfw_platform_interface.dart';

class _PermPlatform extends NsfwPlatformInterface
    with MockPlatformInterfaceMixin {
  PhotoLibraryPermissionStatus photo = PhotoLibraryPermissionStatus.notDetermined;
  PermissionStatus camera = PermissionStatus.notDetermined;
  bool throwOnCamera = false;

  int checkPhotoCalls = 0;
  int requestPhotoCalls = 0;
  int checkCameraCalls = 0;
  int requestCameraCalls = 0;

  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() async {
    checkPhotoCalls++;
    return photo;
  }

  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() async {
    requestPhotoCalls++;
    return photo;
  }

  @override
  Future<PermissionStatus> checkCameraPermission() async {
    checkCameraCalls++;
    if (throwOnCamera) throw UnimplementedError();
    return camera;
  }

  @override
  Future<PermissionStatus> requestCameraPermission() async {
    requestCameraCalls++;
    if (throwOnCamera) throw UnimplementedError();
    return camera;
  }

  // Unused — every test only exercises the permission paths.
  @override
  Future<List<ModelDescriptor>> availableModels() async => const [];

  @override
  Future<void> startScan(ScanConfiguration config) async {}

  @override
  Future<void> cancelScan() async {}

  @override
  Future<void> startCameraScan(CameraConfiguration config) async {}

  @override
  Future<void> stopCameraScan() async {}

  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(
    String localIdentifier, {
    String? modelId,
  }) async => {};

  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream => const Stream.empty();
}

void main() {
  late _PermPlatform platform;

  setUp(() {
    platform = _PermPlatform();
    NsfwPlatformInterface.instance = platform;
  });

  Future<void> pumpView(
    WidgetTester tester, {
    List<PermissionKind>? kinds,
    PermissionLabelBuilder? labelBuilder,
    PermissionChangedCallback? onChanged,
    VoidCallback? onOpenSettings,
    bool refreshOnAppResume = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NsfwPermissionsView(
            kinds: kinds ?? const [
              PermissionKind.photoLibrary,
              PermissionKind.camera,
            ],
            labelBuilder: labelBuilder,
            onPermissionChanged: onChanged,
            onOpenSettings: onOpenSettings,
            refreshOnAppResume: refreshOnAppResume,
          ),
        ),
      ),
    );
    // Let initState's _refreshAll() resolve.
    await tester.pumpAndSettle();
  }

  testWidgets('initial render shows seeded statuses for both rows',
      (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;
    platform.camera = PermissionStatus.denied;

    await pumpView(tester);

    expect(find.text('Photo Library'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Authorized'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
  });

  testWidgets('photo notDetermined → tapping Request invokes requestPermission '
      'and fires onPermissionChanged', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.notDetermined;
    platform.camera = PermissionStatus.authorized;

    final changes = <(PermissionKind, PermissionStatus)>[];
    await pumpView(
      tester,
      onChanged: (k, s) => changes.add((k, s)),
    );

    // Initial poll: photo went notDetermined → notDetermined (no change),
    // camera went notDetermined → authorized (one change event).
    expect(changes, hasLength(1));
    expect(changes.single.$1, PermissionKind.camera);

    // Flip the platform answer so the request actually changes status.
    platform.photo = PhotoLibraryPermissionStatus.authorized;

    final requestBtns = find.text('Request');
    expect(requestBtns, findsOneWidget);
    await tester.tap(requestBtns);
    await tester.pumpAndSettle();

    expect(platform.requestPhotoCalls, 1);
    expect(find.text('Authorized'), findsNWidgets(2));
    expect(changes.last.$1, PermissionKind.photoLibrary);
    expect(changes.last.$2, PermissionStatus.authorized);
  });

  testWidgets('photo denied keeps Request button visible (re-askable)',
      (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.denied;
    platform.camera = PermissionStatus.authorized;

    await pumpView(tester);

    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Request'), findsOneWidget);
    expect(find.text('Open Settings'), findsNothing);
  });

  testWidgets('permanentlyDenied + onOpenSettings → button visible and tappable',
      (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.notDetermined;
    platform.camera = PermissionStatus.permanentlyDenied;

    var openTaps = 0;
    await pumpView(
      tester,
      onOpenSettings: () => openTaps++,
    );

    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(openTaps, 1);
  });

  testWidgets('permanentlyDenied + onOpenSettings == null → no trailing button',
      (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;
    platform.camera = PermissionStatus.permanentlyDenied;

    await pumpView(tester);

    expect(find.text('Open Settings'), findsNothing);
    expect(find.text('Permanently denied'), findsOneWidget);
  });

  testWidgets('camera UnimplementedError surfaces as notDetermined and '
      'request is no-op', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;
    platform.throwOnCamera = true;

    await pumpView(tester);

    expect(find.text('Not determined'), findsOneWidget);
    final requestBtn = find.text('Request');
    expect(requestBtn, findsOneWidget);
    await tester.tap(requestBtn);
    await tester.pumpAndSettle();
    // requestCameraCalls counts even when it throws — graceful fallback.
    expect(platform.requestCameraCalls, 1);
    expect(find.text('Not determined'), findsOneWidget);
  });

  testWidgets('refreshOnAppResume: true re-polls statuses on resume',
      (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.notDetermined;
    platform.camera = PermissionStatus.notDetermined;

    await pumpView(tester);
    final initialPhotoCalls = platform.checkPhotoCalls;
    final initialCameraCalls = platform.checkCameraCalls;
    expect(initialPhotoCalls, 1);
    expect(initialCameraCalls, 1);

    // Simulate app coming back from system Settings.
    final state = WidgetsBinding.instance;
    state.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(platform.checkPhotoCalls, greaterThan(initialPhotoCalls));
    expect(platform.checkCameraCalls, greaterThan(initialCameraCalls));
  });

  testWidgets('refreshOnAppResume: false does not re-poll', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.notDetermined;
    platform.camera = PermissionStatus.notDetermined;

    await pumpView(tester, refreshOnAppResume: false);
    expect(platform.checkPhotoCalls, 1);

    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(platform.checkPhotoCalls, 1);
  });

  testWidgets('only photoLibrary kind → no camera row rendered', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;

    await pumpView(tester, kinds: const [PermissionKind.photoLibrary]);

    expect(find.text('Photo Library'), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
    expect(platform.checkCameraCalls, 0);
  });

  testWidgets('labelBuilder override replaces the row title', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;
    platform.camera = PermissionStatus.authorized;

    await pumpView(
      tester,
      labelBuilder: (kind, status, ctx) => kind == PermissionKind.photoLibrary
          ? 'Fotobibliothek'
          : 'Kamera',
    );

    expect(find.text('Fotobibliothek'), findsOneWidget);
    expect(find.text('Kamera'), findsOneWidget);
    expect(find.text('Photo Library'), findsNothing);
  });

  testWidgets('granted state shows ✓ icon, no Request button', (tester) async {
    platform.photo = PhotoLibraryPermissionStatus.authorized;
    platform.camera = PermissionStatus.limited;

    await pumpView(tester);

    expect(find.text('Request'), findsNothing);
    expect(find.text('Open Settings'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
  });
}
