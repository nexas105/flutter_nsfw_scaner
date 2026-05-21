import 'package:flutter/foundation.dart';

import 'scan_configuration.dart';

/// Options for [NsfwDetector.scheduleBackgroundSweep].
///
/// **Platform integration.** Background scans require host-app wiring on
/// both platforms — the plugin alone cannot register OS-level scheduler
/// hooks. Until each host app completes the integration steps below,
/// `scheduleBackgroundSweep` throws `BackgroundSweepUnavailableError`
/// with a message describing which step is missing.
///
/// ### iOS — `BGTaskScheduler`
///
/// 1. Add the background-processing capability to your target.
/// 2. Add the plugin's identifier to `Info.plist` under
///    `BGTaskSchedulerPermittedIdentifiers`:
///
///    ```xml
///    <key>BGTaskSchedulerPermittedIdentifiers</key>
///    <array>
///      <string>com.nsfw_detect.background_sweep</string>
///    </array>
///    ```
///
/// 3. Register the launch handler **inside `application(_:didFinishLaunchingWithOptions:)`,
///    BEFORE `GeneratedPluginRegistrant.register(...)`** — `BGTaskScheduler`
///    requires handler registration to complete synchronously during app
///    launch. (A helper that does this is shipped in a follow-up PR; until
///    then host apps register manually.)
///
/// 4. Test using the Xcode debugger:
///    `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.nsfw_detect.background_sweep"]`.
///
/// ### Android — `WorkManager`
///
/// 1. Ensure `androidx.work:work-runtime-ktx` is on the runtime classpath
///    (most Flutter apps already have this transitively).
/// 2. No manifest changes required — the plugin's `NsfwSweepWorker` is
///    registered via `WorkManager.getInstance(context).enqueue(...)`
///    inside the channel handler.
///
/// ### Background results
///
/// Per-asset results land in the on-device `ScanCache`. Foreground apps
/// read them via [NsfwDetector.cachedResult] / [NsfwDetector.cacheUpdates]
/// on next launch. A separate background-only event channel is on the
/// roadmap but not in this release.
@immutable
class BackgroundSweepOptions {
  /// Repeat interval. iOS treats this as a hint ("earliest"); the OS
  /// decides actual scheduling. Android's [WorkManager] honours the
  /// 15-minute minimum periodic interval.
  final Duration interval;

  /// When true, the sweep only runs while the device is charging. iOS
  /// equivalent is `BGProcessingTaskRequest.requiresExternalPower`.
  final bool requiresCharging;

  /// When true, the sweep only runs while connected to an unmetered
  /// network. iOS equivalent is `BGProcessingTaskRequest.requiresNetworkConnectivity`.
  final bool requiresWifi;

  /// Scan configuration the background worker dispatches. `resumeFromCheckpoint`
  /// is force-set to `true` so the worker continues whatever foreground state
  /// the user left behind.
  final ScanConfiguration scanConfig;

  const BackgroundSweepOptions({
    this.interval = const Duration(hours: 24),
    this.requiresCharging = true,
    this.requiresWifi = false,
    required this.scanConfig,
  })  : assert(interval >= const Duration(minutes: 15),
            'WorkManager rejects periodic intervals under 15 minutes — '
            'pick a longer cadence');

  /// Wire-shape sent across the MethodChannel.
  Map<String, Object?> toChannelMap() => {
        'intervalSeconds': interval.inSeconds,
        'requiresCharging': requiresCharging,
        'requiresWifi': requiresWifi,
        'scanConfig': scanConfig.toChannelMap(),
      };
}

/// Thrown by [NsfwDetector.scheduleBackgroundSweep] when the host app
/// hasn't completed the platform integration described in
/// [BackgroundSweepOptions]'s doc.
class BackgroundSweepUnavailableError extends StateError {
  BackgroundSweepUnavailableError(String reason)
      : super('Background sweep unavailable — $reason');
}
