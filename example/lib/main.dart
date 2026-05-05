import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'screens/camera_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/headless_scan_screen.dart';
import 'screens/picker_screen.dart';
import 'state/app_settings.dart';

/// Single source of truth for the example app — every screen pulls its
/// colors / spacing / typography from here.
final NsfwTheme appNsfwTheme = NsfwTheme.dark(
  gallery: const NsfwGalleryTheme(
    scaffoldBackgroundColor: Color(0xFF121212),
    badgeOpacity: 0.88,
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    NsfwDetector.instance.setLogging(true);
  }
  final settings = await AppSettings.load();
  runApp(NsfwDetectExampleApp(settings: settings));
}

class NsfwDetectExampleApp extends StatelessWidget {
  final AppSettings settings;
  const NsfwDetectExampleApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) => AppSettingsScope(
        settings: settings,
        child: MaterialApp(
          title: 'NSFW Detect Demo',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: appNsfwTheme.accent,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            scaffoldBackgroundColor:
                appNsfwTheme.gallery.scaffoldBackgroundColor,
            appBarTheme: AppBarTheme(
              backgroundColor: appNsfwTheme.surface,
              foregroundColor: appNsfwTheme.onSurface,
              elevation: 0,
            ),
          ),
          home: const _RootNav(),
        ),
      );
}

class _RootNav extends StatefulWidget {
  const _RootNav();

  @override
  State<_RootNav> createState() => _RootNavState();
}

class _RootNavState extends State<_RootNav> {
  static const _screens = <Widget>[
    GalleryScreen(),
    PickerScreen(),
    HeadlessScanScreen(),
    CameraScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final index = settings.lastTabIndex.clamp(0, _screens.length - 1);
    return Scaffold(
      body: IndexedStack(index: index, children: _screens),
      bottomNavigationBar: NavigationBar(
        backgroundColor: appNsfwTheme.surface,
        selectedIndex: index,
        onDestinationSelected: (i) => settings.lastTabIndex = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_photo_alternate_outlined),
            selectedIcon: Icon(Icons.add_photo_alternate),
            label: 'Picker',
          ),
          NavigationDestination(
            icon: Icon(Icons.code_outlined),
            selectedIcon: Icon(Icons.code),
            label: 'Headless',
          ),
          NavigationDestination(
            icon: Icon(Icons.videocam_outlined),
            selectedIcon: Icon(Icons.videocam),
            label: 'Camera',
          ),
        ],
      ),
    );
  }
}
