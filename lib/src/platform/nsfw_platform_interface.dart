import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import '../api/camera_configuration.dart';
import '../api/model_descriptor.dart';
import '../api/permissions/permission_kind.dart';
import '../api/scan_configuration.dart';
import '../l10n/nsfw_localizations.dart';

/// Snapshot of host-app platform setup. Returned by
/// `NsfwDetector.instance.checkPlatformSetup()` so apps can verify their
/// `Info.plist` (iOS) / `AndroidManifest.xml` declarations are in place
/// *before* invoking any media API — the alternative on iOS is SIGABRT the
/// first time the OS sees a missing `NSPhotoLibraryUsageDescription`.
///
/// Each field is `true` when the corresponding usage description / manifest
/// permission is declared by the host app, `false` when it is missing.
class PlatformSetupReport {
  const PlatformSetupReport({
    required this.photoLibraryUsageDescription,
    required this.cameraUsageDescription,
  });

  /// All-ok constant. Used as the default-implementation return value so
  /// platforms / test mocks that don't override `checkPlatformSetup` don't
  /// surface false negatives.
  const PlatformSetupReport.allOk()
      : photoLibraryUsageDescription = true,
        cameraUsageDescription = true;

  /// iOS: `NSPhotoLibraryUsageDescription` present in `Info.plist`.
  /// Android: `READ_MEDIA_IMAGES`/`READ_MEDIA_VIDEO` (API 33+) or
  /// `READ_EXTERNAL_STORAGE` (API ≤ 32) declared in the manifest.
  final bool photoLibraryUsageDescription;

  /// iOS: `NSCameraUsageDescription` present in `Info.plist`.
  /// Android: `CAMERA` declared in the manifest.
  final bool cameraUsageDescription;

  /// `true` when every checked key is present. Apps can short-circuit on
  /// this in production and only inspect individual fields when surfacing
  /// a setup-guide UI in development builds.
  bool get isComplete =>
      photoLibraryUsageDescription && cameraUsageDescription;

  /// The keys whose declarations are missing on the host app. Empty when
  /// `isComplete` is `true`. Useful for building "add these to Info.plist"
  /// hint UIs.
  List<String> get missingKeys => [
        if (!photoLibraryUsageDescription) 'NSPhotoLibraryUsageDescription',
        if (!cameraUsageDescription) 'NSCameraUsageDescription',
      ];

  factory PlatformSetupReport.fromMap(Map<dynamic, dynamic> map) =>
      PlatformSetupReport(
        photoLibraryUsageDescription:
            map['photoLibraryUsageDescription'] as bool? ?? true,
        cameraUsageDescription:
            map['cameraUsageDescription'] as bool? ?? true,
      );

  @override
  String toString() =>
      'PlatformSetupReport(photo: $photoLibraryUsageDescription, '
      'camera: $cameraUsageDescription)';
}

enum PhotoLibraryPermissionStatus {
  authorized,
  limited,
  denied,
  restricted,
  notDetermined;

  static PhotoLibraryPermissionStatus fromString(String s) => switch (s) {
        'authorized' => PhotoLibraryPermissionStatus.authorized,
        'limited' => PhotoLibraryPermissionStatus.limited,
        'denied' => PhotoLibraryPermissionStatus.denied,
        'restricted' => PhotoLibraryPermissionStatus.restricted,
        _ => PhotoLibraryPermissionStatus.notDetermined,
      };

  /// True when the current grant permits at least some library access —
  /// either full (`authorized`) or selected-assets (`limited`).
  bool get canScan =>
      this == PhotoLibraryPermissionStatus.authorized ||
      this == PhotoLibraryPermissionStatus.limited;

  /// True when the user must change the grant in the system Settings app
  /// (denied or restricted). Permission requests will not re-prompt.
  bool get needsSettingsApp =>
      this == PhotoLibraryPermissionStatus.denied ||
      this == PhotoLibraryPermissionStatus.restricted;

  /// English hint string for debug UIs / logs. Equivalent to calling
  /// [localizedMessage] with [NsfwLocalizationsEn] regardless of
  /// [NsfwLocalizations.current]. Kept for source-level compatibility
  /// with callers from v2.4.x and earlier.
  String get userMessage =>
      localizedMessage(const NsfwLocalizationsEn());

  /// Localized hint string. Defaults to [NsfwLocalizations.current], so
  /// `status.localizedMessage()` honours the app-wide language override
  /// set at startup. Pass an explicit [locale] to ignore the global and
  /// pick a specific bundle inline.
  String localizedMessage([NsfwLocalizations? locale]) {
    final l = locale ?? NsfwLocalizations.current;
    return switch (this) {
      PhotoLibraryPermissionStatus.authorized => l.permissionAuthorized,
      PhotoLibraryPermissionStatus.limited => l.permissionLimited,
      PhotoLibraryPermissionStatus.denied => l.permissionDenied,
      PhotoLibraryPermissionStatus.restricted => l.permissionRestricted,
      PhotoLibraryPermissionStatus.notDetermined =>
        l.permissionNotDetermined,
    };
  }
}

/// Platform-interface contract for nsfw_detect.
///
/// Methods are split into two groups:
///   * **Lifecycle / critical** (abstract — every implementation must provide
///     them): permission, model listing, scan lifecycle, single-asset scan,
///     and the raw event stream. Without these the plugin cannot function.
///   * **Optional / feature** (default impls below): model download, custom
///     URL, logging, cache, picker, file/bytes scanning.
///     Default impls either return safely-ignored values or throw a
///     `UnimplementedError` with a clear message. This lets test mocks stub
///     only what they exercise.
abstract class NsfwPlatformInterface extends PlatformInterface {
  NsfwPlatformInterface() : super(token: _token);
  static final Object _token = Object();

  static NsfwPlatformInterface _instance = NsfwUninitializedPlatform();
  static NsfwPlatformInterface get instance => _instance;
  static set instance(NsfwPlatformInterface instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // ── Lifecycle / critical (abstract) ────────────────────────────────────────

  // Permission
  Future<PhotoLibraryPermissionStatus> requestPermission();
  Future<PhotoLibraryPermissionStatus> checkPermission();

  // Platform-setup preflight. Default returns "ok" so platforms / mocks that
  // haven't wired it up don't surface false negatives. Real native impls
  // override to read Info.plist (iOS) or PackageInfo.requestedPermissions
  // (Android) without triggering the OS permission layer.
  Future<PlatformSetupReport> checkPlatformSetup() async =>
      const PlatformSetupReport.allOk();

  // Models — listing is critical because Dart needs to know what's available.
  Future<List<ModelDescriptor>> availableModels();

  // Scan lifecycle
  Future<void> startScan(ScanConfiguration config);
  Future<void> cancelScan();

  // Camera scan lifecycle
  Future<void> startCameraScan(CameraConfiguration config);
  Future<void> stopCameraScan();

  // Camera permission — non-abstract: native handlers are added in Phase 2 (iOS) /
  // Phase 3 (Android). Default throws so [NsfwDetector] can degrade gracefully to
  // [PermissionStatus.notDetermined] until the native side lands.
  Future<PermissionStatus> checkCameraPermission() => throw UnimplementedError(
      'checkCameraPermission is not yet implemented for this platform');
  Future<PermissionStatus> requestCameraPermission() =>
      throw UnimplementedError(
          'requestCameraPermission is not yet implemented for this platform');

  // Single asset. [roi] is a normalised `{x, y, width, height}` map in
  // `[0, 1]` passed straight to the native side; when null the full asset is
  // scanned. Native implementations that don't support ROI cropping should
  // ignore the key.
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
      {String? modelId, Map<String, double>? roi});

  // Event stream (raw maps from native)
  Stream<Map<dynamic, dynamic>> get scanEventStream;

  // ── Optional / feature (default impls) ─────────────────────────────────────

  /// Compile / warm the model. Default no-op so test mocks don't need to stub.
  Future<void> preloadModel(String modelId) async {}

  /// Reset scan state (clears native checkpoints, etc.). Default no-op.
  Future<void> resetScan() async {}

  /// Picker scan. Default throws — enable by overriding in your native impl.
  Future<void> startPickAndScan(ScanConfiguration config, int maxItems) =>
      throw UnimplementedError(
          'startPickAndScan is not implemented by this platform');

  /// Pure media picker (no classification). Default throws.
  Future<List<Map<dynamic, dynamic>>> pickMedia({
    required String type,
    required bool multiple,
    int? maxItems,
  }) =>
      throw UnimplementedError(
          'pickMedia is not implemented by this platform');

  /// Scan an image file from path. Default throws. [roi] is a normalised
  /// `{x, y, width, height}` map in `[0, 1]`; native implementations that
  /// don't support cropping should ignore the key.
  Future<Map<dynamic, dynamic>> scanFilePath(String filePath,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError(
          'scanFilePath is not implemented by this platform');

  /// Scan raw image bytes. Default throws. See [scanFilePath] for the
  /// [roi] contract.
  Future<Map<dynamic, dynamic>> scanImageBytes(Uint8List bytes,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError(
          'scanImageBytes is not implemented by this platform');

  /// Download a downloadable model. Default throws.
  Future<bool> downloadModel(String modelId, {String? url}) =>
      throw UnimplementedError(
          'downloadModel is not implemented by this platform');

  /// Delete a previously-downloaded model. Default no-op.
  Future<void> deleteModel(String modelId) async {}

  /// Set a custom download URL for a model. Default no-op.
  Future<void> setModelUrl(String modelId, String url) async {}

  /// Toggle native logging. Default no-op.
  Future<void> setLogging(bool enabled) async {}

  /// Clear the persistent scan-result cache. Default no-op.
  Future<void> clearScanCache({String? modelId}) async {}

  // v2.3.0 — cache lookup, prefetch, native redaction.

  /// Schedule a recurring background scan. Default throws — host-app
  /// integration is required (Info.plist on iOS, WorkManager classpath
  /// on Android — see `BackgroundSweepOptions` docs).
  Future<void> scheduleBackgroundSweep(Map<String, Object?> options) =>
      throw UnimplementedError(
          'scheduleBackgroundSweep is not implemented by this platform');

  /// Cancel any pending background sweep. Default no-op — safe to call
  /// even if none was scheduled.
  Future<void> cancelBackgroundSweep() async {}

  /// Register a custom model descriptor at runtime. Returns the resolved
  /// asset path the native side will load from. Default throws.
  Future<String> registerModel(Map<String, Object?> registration) =>
      throw UnimplementedError(
          'registerModel is not implemented by this platform');

  /// Look up a cached scan record for [localIdentifier] without triggering a
  /// re-scan. Returns the wire-shape map (mirrors [scanSingleAsset]) when a
  /// row exists, or `null` on miss. Default throws.
  Future<Map<dynamic, dynamic>?> cachedResult(
    String localIdentifier, {
    String? modelId,
  }) =>
      throw UnimplementedError(
          'cachedResult is not implemented by this platform');

  /// Signal the native scan loop to skip the next asset it would process.
  /// Best-effort: one outstanding skip is consumed by the next per-asset
  /// task that checks the flag. No effect when no scan is running.
  ///
  /// Default no-op so test fakes don't need to stub this. Real native
  /// impls forward to the active `ScanSessionTask`.
  Future<void> skipCurrentAsset() async {}

  /// Pre-warm the native asset cache for the given local identifiers so the
  /// next [scanSingleAsset] or library scan can decode them with less I/O
  /// pressure. Default no-op — platforms without a meaningful warm-cache
  /// implementation just return.
  Future<void> prefetchAssets(
    List<String> localIdentifiers, {
    String? modelId,
  }) async {}

  /// Load a downscaled thumbnail (JPEG bytes) for the photo-library asset
  /// identified by [localIdentifier]. Returns `null` when the asset cannot be
  /// resolved or decoded. [maxWidth]/[maxHeight] are an upper bound in logical
  /// pixels; aspect ratio is preserved. Default throws.
  Future<Uint8List?> loadThumbnail(
    String localIdentifier, {
    int maxWidth = 256,
    int maxHeight = 256,
  }) =>
      throw UnimplementedError(
          'loadThumbnail is not implemented by this platform');

  /// Export the original bytes of a photo-library asset (image or video) to a
  /// temp file and return its absolute path, or `null` when the asset can't be
  /// resolved. Default throws.
  Future<String?> exportAsset(String localIdentifier) =>
      throw UnimplementedError(
          'exportAsset is not implemented by this platform');

  /// Enumerate photo-library asset identifiers (creationDate desc), so a
  /// Dart-driven batch *ensemble* scan can iterate them. [mediaType] is
  /// `'image'` (default), `'video'`, or `'any'`; [limit] caps the count
  /// (0/null = all). Default throws.
  Future<List<String>> listAssetIdentifiers({
    String mediaType = 'image',
    int? limit,
  }) =>
      throw UnimplementedError(
          'listAssetIdentifiers is not implemented by this platform');

  // ── Asset management (v2.7.0) ───────────────────────────────────────────────
  // Native operations on the *original* PHAsset. Each default throws so test
  // fakes opt in explicitly; the method-channel impl forwards to PhotoKit.

  /// Toggle the favorite flag on the asset. See [NsfwDetector.setAssetFavorite].
  Future<void> setAssetFavorite(String localIdentifier, bool favorite) =>
      throw UnimplementedError(
          'setAssetFavorite is not implemented by this platform');

  /// Toggle the hidden flag on the asset. See [NsfwDetector.setAssetHidden].
  Future<void> setAssetHidden(String localIdentifier, bool hidden) =>
      throw UnimplementedError(
          'setAssetHidden is not implemented by this platform');

  /// Delete assets (OS shows its own confirmation). Returns `true` when the
  /// user confirmed, `false` when they cancelled. See [NsfwDetector.deleteAssets].
  Future<bool> deleteAssets(List<String> localIdentifiers) =>
      throw UnimplementedError(
          'deleteAssets is not implemented by this platform');

  /// List user albums as `{id, title, count, isUserAlbum}` maps.
  Future<List<Map<dynamic, dynamic>>> listAlbums() =>
      throw UnimplementedError(
          'listAlbums is not implemented by this platform');

  /// Create an album, returning its new local identifier.
  Future<String> createAlbum(String title) =>
      throw UnimplementedError(
          'createAlbum is not implemented by this platform');

  /// Add assets to an album. See [NsfwDetector.addAssetsToAlbum].
  Future<void> addAssetsToAlbum(List<String> localIdentifiers, String albumId) =>
      throw UnimplementedError(
          'addAssetsToAlbum is not implemented by this platform');

  /// Remove assets from an album. See [NsfwDetector.removeAssetsFromAlbum].
  Future<void> removeAssetsFromAlbum(
          List<String> localIdentifiers, String albumId) =>
      throw UnimplementedError(
          'removeAssetsFromAlbum is not implemented by this platform');

  /// Move assets to [toAlbumId] (add), optionally removing them from
  /// [fromAlbumId]. See [NsfwDetector.moveAssetsToAlbum].
  Future<void> moveAssetsToAlbum(
    List<String> localIdentifiers,
    String toAlbumId, {
    String? fromAlbumId,
  }) =>
      throw UnimplementedError(
          'moveAssetsToAlbum is not implemented by this platform');

  /// Redact the supplied image bytes against the given detection list. Mode
  /// strings: `"blur"`, `"pixelate"`, `"blackBox"`. Default throws.
  Future<Uint8List> redactBytes({
    required Uint8List bytes,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputFormat,
  }) =>
      throw UnimplementedError(
          'redactBytes is not implemented by this platform');

  /// Redact an image file on disk. [outputPath] when null writes to a sibling
  /// temporary file. Returns the on-disk path of the redacted output. Default
  /// throws.
  Future<String> redactFile({
    required String inputPath,
    required List<Map<String, Object?>> detections,
    required String mode,
    required double intensity,
    String? outputPath,
  }) =>
      throw UnimplementedError(
          'redactFile is not implemented by this platform');
}

/// Exposed so NsfwDetector can detect the uninitialized state.
class NsfwUninitializedPlatform extends NsfwPlatformInterface {
  @override
  Future<PhotoLibraryPermissionStatus> requestPermission() =>
      throw UnimplementedError();
  @override
  Future<PhotoLibraryPermissionStatus> checkPermission() =>
      throw UnimplementedError();
  @override
  Future<PlatformSetupReport> checkPlatformSetup() => throw UnimplementedError();
  @override
  Future<List<ModelDescriptor>> availableModels() => throw UnimplementedError();
  @override
  Future<void> startScan(ScanConfiguration config) =>
      throw UnimplementedError();
  @override
  Future<void> cancelScan() => throw UnimplementedError();
  @override
  Future<void> startCameraScan(CameraConfiguration config) =>
      throw UnimplementedError();
  @override
  Future<void> stopCameraScan() => throw UnimplementedError();
  @override
  Future<Map<dynamic, dynamic>> scanSingleAsset(String localIdentifier,
          {String? modelId, Map<String, double>? roi}) =>
      throw UnimplementedError();
  @override
  Stream<Map<dynamic, dynamic>> get scanEventStream =>
      throw UnimplementedError();
}
