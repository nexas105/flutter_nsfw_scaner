# Platform Gotchas

Platform-specific behaviour that has bitten real integrations. Skim before shipping.

## iOS: HEIC images

iOS captures and exports images as HEIC by default. When the system picker or library scan delivers a HEIC asset, the plugin transcodes via Core Image on the native side before inference — no extra setup required from your app.

- Typical HEIC file sizes: 1.5–3 MB for a 12 MP capture (roughly half of JPEG at equivalent quality).
- Screenshots captured on iOS itself are PNG, not HEIC.
- Images shared from non-Apple sources (Android exports, WhatsApp re-encodes, web downloads) are almost always JPEG or PNG, not HEIC.
- If you pre-process images in Dart before calling `scanBytes`, make sure your decoder understands the HEIC format you pass in. The plugin's native path does, but `dart:ui`'s `decodeImageFromList` does not.

## iOS: Limited photo library (iOS 14+)

When the user picks "Selected Photos…" instead of "All Photos", `PhotoLibraryPermissionStatus.limited` is returned. The plugin's library scan respects the user selection — `startScan` enumerates only the assets the user granted access to.

- `PhotoLibraryPermissionStatus.canScan` returns `true` for both `authorized` and `limited`.
- iOS does not allow your app to re-prompt for full access programmatically. The only path back is the system Settings app.
- If you need to surface a "change selection" affordance, link the user to `app-settings:` and let them adjust the selection there.

## iOS: App Store Privacy Manifest

If you ship to the App Store, Apple expects a `PrivacyInfo.xcprivacy` file that declares photo-library access intent and any "required reason" API usage. Add the file to your iOS target and include entries similar to:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>CA92.1</string>
      </array>
    </dict>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array>
        <string>C617.1</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
```

For photo-library access itself, declare the purpose string in `Info.plist` (`NSPhotoLibraryUsageDescription`) and select the appropriate reason code in App Store Connect when submitting (e.g. `1C8F.1` for user-initiated content selection). The plugin only reads photo metadata; it does not write back to the library.

Always cross-check the [latest Apple reason-code list](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api) — Apple updates these periodically.

## Android: Photo Picker (Android 13+)

`NsfwDetector.pickMedia` and `pickAndScan` use the system Photo Picker on Android via `ACTION_PICK_IMAGES` on API 33+ (with the Google Play Services backport reaching back to API 21). The Photo Picker is a separate process — your app never sees images the user did not pick.

- No `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` permission is required for picker workflows.
- Library scans via `startScan` still need full media-read permission. Declare `READ_MEDIA_IMAGES` and/or `READ_MEDIA_VIDEO` on Android 13+, and the legacy `READ_EXTERNAL_STORAGE` (with `android:maxSdkVersion="32"`) for Android 12 and earlier.

## Android: Photo Picker partial access (Android 14)

Android 14 introduced `READ_MEDIA_VISUAL_USER_SELECTED`, letting the user grant access to a subset of their photos instead of the whole library. If your app declares this permission alongside `READ_MEDIA_IMAGES`, the system can surface a chooser similar to iOS Limited Library.

The plugin handles partial access transparently: library scans enumerate whatever the OS exposes. The selection chooser is system UI; your app cannot influence which assets the user grants.

```xml
<uses-permission
  android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED" />
```

## Android: ProGuard / R8 rules

R8 can shrink away TFLite tensor classes and CameraX lifecycle internals during release builds, surfacing as runtime `ClassNotFoundException` or "could not load delegate" errors. Add a `consumer-rules.pro` (or extend your app's `proguard-rules.pro`) with:

```pro
-keep class org.tensorflow.lite.** { *; }
-keep class androidx.camera.** { *; }
-keepattributes *Annotation*
```

If you opt into the GPU delegate via `ScanConfiguration.androidDelegate`, also keep:

```pro
-keep class org.tensorflow.lite.gpu.** { *; }
```

## Android: minSdk implications

The plugin's `minSdkVersion` is 24. Behaviour varies by Android version:

| API level | What works |
| --- | --- |
| 24–28 (Android 7–9) | Headless scans (`scanFile`, `scanBytes`), library scans via `READ_EXTERNAL_STORAGE`, camera scanning. No Photo Picker; `pickMedia` falls back to the legacy chooser. |
| 29–32 (Android 10–12) | Scoped storage. Library scans still use `READ_EXTERNAL_STORAGE`. Picker still legacy. |
| 33 (Android 13) | Photo Picker available natively. Library scans need `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO`. |
| 34+ (Android 14) | Partial access via `READ_MEDIA_VISUAL_USER_SELECTED`. Foreground-service-camera restrictions apply if you run camera scans from a service. |

Inference performance is dominated by device class, not API level. A 2019 mid-range device on Android 9 will outperform a 2023 budget device on Android 14 in TFLite CPU throughput.
