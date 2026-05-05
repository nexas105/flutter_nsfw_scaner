import '../../platform/nsfw_platform_interface.dart';

/// Identifies which permission a row in [NsfwPermissionsView] represents.
enum PermissionKind {
  photoLibrary,
  camera;

  /// Human-readable English label shipped by the plugin.
  ///
  /// Localisation is the host app's responsibility — pass a custom
  /// `labelBuilder` to [NsfwPermissionsView] to override.
  String get defaultLabel => switch (this) {
        PermissionKind.photoLibrary => 'Photo Library',
        PermissionKind.camera => 'Camera',
      };
}

/// Aggregate permission status the widget renders.
///
/// Maps from the existing [PhotoLibraryPermissionStatus] (gallery scan)
/// and the future camera-permission status (Phase 2 / 3 native handlers).
enum PermissionStatus {
  authorized,
  limited,
  denied,
  permanentlyDenied,
  restricted,
  notDetermined;

  bool get isGranted =>
      this == PermissionStatus.authorized ||
      this == PermissionStatus.limited;

  bool get canRequest =>
      this == PermissionStatus.notDetermined ||
      this == PermissionStatus.denied;

  bool get needsSettings =>
      this == PermissionStatus.permanentlyDenied ||
      this == PermissionStatus.restricted;

  static PermissionStatus fromString(String? s) => switch (s) {
        'authorized' => PermissionStatus.authorized,
        'limited' => PermissionStatus.limited,
        'denied' => PermissionStatus.denied,
        'permanentlyDenied' || 'permanently_denied' =>
          PermissionStatus.permanentlyDenied,
        'restricted' => PermissionStatus.restricted,
        _ => PermissionStatus.notDetermined,
      };
}

extension PhotoLibraryPermissionStatusMapping on PhotoLibraryPermissionStatus {
  PermissionStatus toPermissionStatus() => switch (this) {
        PhotoLibraryPermissionStatus.authorized => PermissionStatus.authorized,
        PhotoLibraryPermissionStatus.limited => PermissionStatus.limited,
        PhotoLibraryPermissionStatus.denied => PermissionStatus.denied,
        PhotoLibraryPermissionStatus.restricted => PermissionStatus.restricted,
        PhotoLibraryPermissionStatus.notDetermined =>
          PermissionStatus.notDetermined,
      };
}
