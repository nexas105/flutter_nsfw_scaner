import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:nsfw_detect/nsfw_detect.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent demo-app state. Mirrors what an App-Store-shipping consumer
/// would build: scan configuration + gallery filter + the last-used tab
/// survive process restart.
///
/// Owned at the top of the widget tree via [AppSettingsScope]; read with
/// `AppSettingsScope.of(context)`.
class AppSettings extends ChangeNotifier {
  static const _kConfig = 'nsfw_demo.config';
  static const _kFilter = 'nsfw_demo.filter';
  static const _kTab = 'nsfw_demo.lastTabIndex';
  static const _kCameraModelId = 'nsfw_demo.cameraModelId';

  final SharedPreferences _prefs;

  ScanConfiguration _config;
  NsfwGalleryFilter _filter;
  int _lastTabIndex;
  String? _cameraModelId;

  AppSettings._(
    this._prefs,
    this._config,
    this._filter,
    this._lastTabIndex,
    this._cameraModelId,
  );

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();

    ScanConfiguration cfg;
    final cfgRaw = prefs.getString(_kConfig);
    if (cfgRaw != null) {
      try {
        cfg = ScanConfiguration.fromJson(
            jsonDecode(cfgRaw) as Map<String, dynamic>);
      } catch (_) {
        cfg = const ScanConfiguration();
      }
    } else {
      cfg = const ScanConfiguration();
    }

    NsfwGalleryFilter filter;
    final filterRaw = prefs.getString(_kFilter);
    if (filterRaw != null) {
      try {
        filter = NsfwGalleryFilter.fromJson(
            jsonDecode(filterRaw) as Map<String, dynamic>);
      } catch (_) {
        filter = NsfwGalleryFilter.passthrough;
      }
    } else {
      filter = NsfwGalleryFilter.passthrough;
    }

    final tab = prefs.getInt(_kTab) ?? 0;
    final cameraModelId = prefs.getString(_kCameraModelId);
    return AppSettings._(prefs, cfg, filter, tab, cameraModelId);
  }

  ScanConfiguration get config => _config;
  NsfwGalleryFilter get filter => _filter;
  int get lastTabIndex => _lastTabIndex;

  /// Persisted camera-screen model selection. `null` means "no choice
  /// yet" — the camera screen falls back to the first available model.
  String? get cameraModelId => _cameraModelId;

  set config(ScanConfiguration v) {
    if (v == _config) return;
    _config = v;
    _prefs.setString(_kConfig, jsonEncode(v.toJson()));
    notifyListeners();
  }

  set filter(NsfwGalleryFilter v) {
    if (v == _filter) return;
    _filter = v;
    _prefs.setString(_kFilter, jsonEncode(v.toJson()));
    notifyListeners();
  }

  set lastTabIndex(int v) {
    if (v == _lastTabIndex) return;
    _lastTabIndex = v;
    _prefs.setInt(_kTab, v);
    notifyListeners();
  }

  set cameraModelId(String? v) {
    if (v == _cameraModelId) return;
    _cameraModelId = v;
    if (v == null) {
      _prefs.remove(_kCameraModelId);
    } else {
      _prefs.setString(_kCameraModelId, v);
    }
    notifyListeners();
  }
}

/// Inherited-notifier wrapper so descendants can rebuild on changes without
/// a third-party state-management dependency.
class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppSettings of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, 'AppSettingsScope missing — wrap MaterialApp.');
    return scope!.notifier!;
  }
}
