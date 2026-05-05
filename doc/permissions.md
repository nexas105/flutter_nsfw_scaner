# Permissions

`nsfw_detect` can scan through several workflows. Each workflow has different permission needs.

## Permission matrix

| Workflow | Photo library permission | Camera permission |
| --- | --- | --- |
| `scanFile` | No, if your app already has the file path | No |
| `scanBytes` | No | No |
| `pickAndScan` | No full-library permission; native picker grants selected access | No |
| `pickMedia` then `scanAsset` | No full-library permission for picked items | No |
| `startScan` library scan | Yes | No |
| `NsfwCameraView` or `startCameraScan` | No | Yes |

## iOS setup

Add photo-library usage text when you scan the library:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>This app checks selected media on-device before it is used.</string>
```

Add camera usage text when using camera scanning:

```xml
<key>NSCameraUsageDescription</key>
<string>This app checks camera frames on-device.</string>
```

Ensure the iOS deployment target is 16 or higher:

```ruby
platform :ios, '16.0'
```

## Android setup

Declare the permissions used by your app:

```xml
<!-- Photo library, Android 13+ -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- Photo library, Android 12 and below -->
<uses-permission
  android:name="android.permission.READ_EXTERNAL_STORAGE"
  android:maxSdkVersion="32" />

<!-- Camera, only required for camera workflows -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
```

## Requesting photo-library access

```dart
final status = await NsfwDetector.instance.checkPermission();

if (status == PhotoLibraryPermissionStatus.notDetermined) {
  final requested = await NsfwDetector.instance.requestPermission();
  if (requested != PhotoLibraryPermissionStatus.authorized &&
      requested != PhotoLibraryPermissionStatus.limited) {
    return;
  }
}
```

`authorized` and `limited` can both be used for library scanning. Handle `denied` and `restricted` with your own app settings or fallback UI.

## Requesting camera access

```dart
final status = await NsfwDetector.instance.requestCameraPermission();

if (!status.isGranted) {
  // Show settings instructions or disable camera scanning.
  return;
}
```

For a ready-made permission screen, use `NsfwPermissionsView`.

```dart
NsfwPermissionsView(
  onOpenSettings: () {
    // Open your app's settings page with your preferred package.
  },
  onPermissionChanged: (kind, status) {
    // Update app state or analytics that your app owns.
  },
);
```
