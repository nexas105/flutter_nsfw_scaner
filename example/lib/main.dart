import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/animated_image_demo_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/crop_resistant_demo_screen.dart';
import 'screens/detection_demo_screen.dart';
import 'screens/error_states_screen.dart';
import 'screens/frame_stream_demo_screen.dart';
import 'screens/gallery_screen.dart';
import 'screens/headless_scan_screen.dart';
import 'screens/models_screen.dart';
import 'screens/moderation_gate_screen.dart';
import 'screens/picker_screen.dart';
import 'screens/raw_format_demo_screen.dart';
import 'state/app_settings.dart';

/// Persisted preference key for the light/dark toggle (#32).
const String _kThemeMode = 'nsfw_demo.themeMode';

/// Global, mutable [ThemeMode] notifier driving [MaterialApp.themeMode].
/// Stored at module scope so any deep child can flip it via
/// `themeModeNotifier.value = ...`. Loaded from disk in [main].
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.dark);

/// Persists the new mode to [SharedPreferences]. Failures are non-fatal —
/// the in-memory notifier is the source of truth at runtime.
Future<void> _persistThemeMode(ThemeMode mode) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode.name);
  } catch (_) {/* silent — keep UX responsive */}
}

/// Returns the active [NsfwTheme] for [mode], resolving `system` against the
/// platform brightness in [context]. Used in screens that still consume the
/// legacy `appNsfwTheme` global (e.g. accent / surface colours).
NsfwTheme resolveNsfwTheme(BuildContext context, ThemeMode mode) {
  final platformBrightness = MediaQuery.platformBrightnessOf(context);
  final effective = switch (mode) {
    ThemeMode.dark => Brightness.dark,
    ThemeMode.light => Brightness.light,
    ThemeMode.system => platformBrightness,
  };
  return effective == Brightness.dark
      ? NsfwTheme.dark(
          gallery: const NsfwGalleryTheme(
            scaffoldBackgroundColor: Color(0xFF121212),
            badgeOpacity: 0.88,
          ),
        )
      : NsfwTheme.light(
          gallery: const NsfwGalleryTheme(
            scaffoldBackgroundColor: Color(0xFFF7F7F8),
            badgeOpacity: 0.88,
          ),
        );
}

/// Legacy single-source-of-truth theme retained for screens that still read
/// it as a const-ish global. Updated whenever [themeModeNotifier] flips.
/// New screens prefer [resolveNsfwTheme] via context.
NsfwTheme appNsfwTheme = NsfwTheme.dark(
  gallery: const NsfwGalleryTheme(
    scaffoldBackgroundColor: Color(0xFF121212),
    badgeOpacity: 0.88,
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();

  // Hydrate persisted theme mode (#32) — silent fallback to dark on error.
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kThemeMode);
    if (raw != null) {
      themeModeNotifier.value = ThemeMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => ThemeMode.dark,
      );
    }
  } catch (_) {/* default already dark */}

  // Demo of NsfwDetector.init — preloads the default model and toggles
  // native logging based on the build mode. tolerateModelErrors (default
  // true) keeps the app launching even if the model fails to load.
  final report = await NsfwDetector.instance.init(const NsfwInitOptions(
    preloadModels: [ModelIds.openNsfw2],
    enableNativeLogging: kDebugMode,
  ));
  if (kDebugMode) {
    debugPrint('nsfw_detect init: $report');
  }

  runApp(NsfwDetectExampleApp(settings: settings));
}

class NsfwDetectExampleApp extends StatelessWidget {
  final AppSettings settings;
  const NsfwDetectExampleApp({super.key, required this.settings});

  ThemeData _materialThemeFor(Brightness brightness) {
    final nsfw = brightness == Brightness.dark
        ? NsfwTheme.dark(
            gallery: const NsfwGalleryTheme(
              scaffoldBackgroundColor: Color(0xFF121212),
              badgeOpacity: 0.88,
            ),
          )
        : NsfwTheme.light(
            gallery: const NsfwGalleryTheme(
              scaffoldBackgroundColor: Color(0xFFF7F7F8),
              badgeOpacity: 0.88,
            ),
          );
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: nsfw.accent,
        brightness: brightness,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: nsfw.gallery.scaffoldBackgroundColor,
      appBarTheme: AppBarTheme(
        backgroundColor: nsfw.surface,
        foregroundColor: nsfw.onSurface,
        elevation: 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppSettingsScope(
        settings: settings,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: themeModeNotifier,
          builder: (context, mode, _) {
            // Keep the legacy global in sync for screens that read it directly.
            appNsfwTheme = mode == ThemeMode.light
                ? NsfwTheme.light(
                    gallery: const NsfwGalleryTheme(
                      scaffoldBackgroundColor: Color(0xFFF7F7F8),
                      badgeOpacity: 0.88,
                    ),
                  )
                : NsfwTheme.dark(
                    gallery: const NsfwGalleryTheme(
                      scaffoldBackgroundColor: Color(0xFF121212),
                      badgeOpacity: 0.88,
                    ),
                  );
            return MaterialApp(
              title: 'NSFW Detect Demo',
              debugShowCheckedModeBanner: false,
              themeMode: mode,
              theme: _materialThemeFor(Brightness.light),
              darkTheme: _materialThemeFor(Brightness.dark),
              home: const _RootNav(),
            );
          },
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

  void _toggleTheme() {
    final current = themeModeNotifier.value;
    final next =
        current == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    themeModeNotifier.value = next;
    _persistThemeMode(next);
  }

  void _openModerationGate() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModerationGateScreen()),
    );
  }

  void _openErrorStates() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ErrorStatesScreen()),
    );
  }

  void _openModels() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModelsScreen()),
    );
  }

  void _openDetectionDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DetectionDemoScreen()),
    );
  }

  void _openFrameStreamDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FrameStreamDemoScreen()),
    );
  }

  void _openAnimatedImageDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AnimatedImageDemoScreen()),
    );
  }

  void _openRawFormatDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RawFormatDemoScreen()),
    );
  }

  void _openCropResistantDemo() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CropResistantDemoScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final index = settings.lastTabIndex.clamp(0, _screens.length - 1);
    final mode = themeModeNotifier.value;
    final isDark = mode == ThemeMode.dark;
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const DrawerHeader(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('NSFW Detect Demo',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text('Plugin example app'),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: const Text('Moderation Gate'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openModerationGate();
                },
              ),
              ListTile(
                leading: const Icon(Icons.error_outline_rounded),
                title: const Text('Error Recovery'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openErrorStates();
                },
              ),
              ListTile(
                leading: const Icon(Icons.dataset_outlined),
                title: const Text('Models'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openModels();
                },
              ),
              ListTile(
                leading: const Icon(Icons.scatter_plot_outlined),
                title: const Text('Detection Demo'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openDetectionDemo();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.live_tv_outlined),
                title: const Text('Frame Stream'),
                subtitle: const Text('Live throttled frame scanner'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openFrameStreamDemo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.gif_box_outlined),
                title: const Text('Animated Image'),
                subtitle: const Text('GIF / WebP frame sampling'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openAnimatedImageDemo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.camera_outlined),
                title: const Text('RAW Format'),
                subtitle: const Text('CR2 / NEF / ARW / DNG'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openRawFormatDemo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.crop_outlined),
                title: const Text('Crop-Resistant Cache'),
                subtitle: const Text('Block-level pHash lookup'),
                onTap: () {
                  Navigator.of(context).pop();
                  _openCropResistantDemo();
                },
              ),
              const Divider(),
              SwitchListTile(
                title: const Text('Dark mode'),
                secondary: Icon(isDark
                    ? Icons.dark_mode_outlined
                    : Icons.light_mode_outlined),
                value: isDark,
                onChanged: (_) => _toggleTheme(),
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        title: const Text('NSFW Detect Demo'),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            onPressed: _toggleTheme,
          ),
        ],
      ),
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
