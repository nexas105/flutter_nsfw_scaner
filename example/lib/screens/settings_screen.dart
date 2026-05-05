import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import '../main.dart';

class SettingsScreen extends StatefulWidget {
  final ScanConfiguration currentConfig;
  const SettingsScreen({super.key, required this.currentConfig});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ScanConfiguration _config;

  @override
  void initState() {
    super.initState();
    _config = widget.currentConfig;
  }

  void _save() => Navigator.of(context).pop(_config);

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: appNsfwTheme.gallery.scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('Scan Settings'),
          backgroundColor: appNsfwTheme.surface,
          actions: [
            TextButton(
              onPressed: _save,
              child: Text(
                'Save',
                style: TextStyle(
                  color: appNsfwTheme.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.all(appNsfwTheme.spacing.lg),
          children: [
            NsfwPermissionsView(
              theme: appNsfwTheme,
              onOpenSettings: AppSettings.openAppSettings,
              onPermissionChanged: (kind, status) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content: Text('${kind.defaultLabel}: ${status.name}'),
                  ),
                );
              },
            ),
            SizedBox(height: appNsfwTheme.spacing.lg),
            NsfwSettingsPanel(
              current: _config,
              theme: appNsfwTheme,
              onChanged: (c) => setState(() => _config = c),
            ),
          ],
        ),
      );
}
