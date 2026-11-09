import BackgroundTasks
import Foundation

/// Wraps `BGTaskScheduler` for the v2.3.0 periodic-sweep API
/// (`NsfwDetector.scheduleBackgroundSweep`). Pendant to
/// `android/.../background/NsfwSweepWorker.kt`.
///
/// Lifecycle:
///   1. Plugin `register(with:)` calls [registerLaunchHandlerIfPossible] —
///      registers a `BGTaskScheduler` handler IFF the identifier is listed
///      in the host app's `Info.plist BGTaskSchedulerPermittedIdentifiers`.
///      Apps that don't opt in pay nothing.
///   2. Dart calls `scheduleBackgroundSweep(options)` → [schedule] persists
///      the options to `UserDefaults` and submits a `BGProcessingTaskRequest`.
///   3. iOS fires the launch handler at its discretion; the handler runs
///      `NsfwDetectIosPlugin.performBackgroundGalleryScan(...)` against the
///      persisted scan config, then submits the next request so the sweep
///      keeps repeating.
///   4. Dart calls `cancelBackgroundSweep()` → [cancel] removes the
///      pending request and clears persisted options so a stale launch
///      can't reschedule itself.
enum BackgroundSweepScheduler {

    /// Identifier the host app must add to
    /// `Info.plist > BGTaskSchedulerPermittedIdentifiers`. Locked at compile
    /// time — changing this string breaks every host app's plist.
    static let taskIdentifier = "com.nsfw_detect.background_sweep"

    private static let optionsKey = "nsfw_detect.background_sweep.options"

    /// True iff the host app added [taskIdentifier] to the permitted-tasks
    /// array. Read once on registration; the plist doesn't change at runtime.
    static var hostAppConfigured: Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey:
            "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.contains(taskIdentifier)
    }

    /// Called from `NsfwDetectIosPlugin.register(with:)`. Registers the
    /// launch handler IFF the host app has opted in. No-op otherwise so
    /// apps that don't use background sweep don't get a crash on launch.
    static func registerLaunchHandlerIfPossible() {
        guard hostAppConfigured else {
            // Documented contract — host app must opt in via Info.plist.
            // We don't error here; `schedule` is what raises the typed
            // error so the Dart caller sees it on first use.
            return
        }
        // Apple docs: "An app must register all of its background task
        // identifiers before the end of application(_:didFinishLaunching…)".
        // Plugin registration runs from inside that scope (via
        // GeneratedPluginRegistrant.register), so this is the legal place.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handleLaunch(task as! BGProcessingTask)
        }
    }

    /// Schedule the next sweep. Persists [options] so the launch handler
    /// can rebuild the scan config when iOS fires the task. Returns the
    /// earliest-begin date the OS will honour.
    static func schedule(options: [String: Any]) throws {
        guard hostAppConfigured else {
            throw NSError(domain: "NsfwDetect", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Host app Info.plist is missing BGTaskSchedulerPermittedIdentifiers entry '\(taskIdentifier)'",
            ])
        }
        UserDefaults.standard.set(options, forKey: optionsKey)
        try submitRequest(options: options)
    }

    /// Cancel any pending sweep and clear persisted state.
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        UserDefaults.standard.removeObject(forKey: optionsKey)
    }

    // MARK: - Internal

    private static func submitRequest(options: [String: Any]) throws {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        let intervalSeconds = (options["intervalSeconds"] as? Int) ?? 86_400
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(intervalSeconds))
        request.requiresExternalPower    = (options["requiresCharging"] as? Bool) ?? true
        request.requiresNetworkConnectivity = (options["requiresWifi"] as? Bool) ?? false
        try BGTaskScheduler.shared.submit(request)
    }

    private static func handleLaunch(_ task: BGProcessingTask) {
        // Re-arm the next sweep first — Apple docs warn that forgetting
        // to resubmit here is the #1 cause of "my BG task only runs once".
        if let options = UserDefaults.standard.dictionary(forKey: optionsKey) {
            try? submitRequest(options: options)
        }

        let modelId: String = {
            if let opts = UserDefaults.standard.dictionary(forKey: optionsKey),
               let cfg = opts["scanConfig"] as? [String: Any],
               let id = cfg["modelId"] as? String {
                return id
            }
            return "open_nsfw_2"
        }()

        // Bail cleanly if iOS times us out. We don't try to checkpoint
        // mid-flight here — ScanSessionTask already persists its own
        // checkpoint each iteration via ScanCheckpoint, so a hard stop
        // just resumes from the next launch.
        task.expirationHandler = {
            NSLog("[NSFW] BG sweep expired — iOS reclaimed the runtime")
        }

        NsfwDetectIosPlugin.performBackgroundGalleryScan(modelId: modelId) { success in
            task.setTaskCompleted(success: success)
        }
    }
}
