import Flutter
import UIKit
import Photos

@objc public class NsfwDetectIosPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        runMigrations()  // ← migration guard — must be first

        let methodChannel = FlutterMethodChannel(
            name: ChannelConstants.methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: ChannelConstants.eventChannelName,
            binaryMessenger: registrar.messenger()
        )

        // The sink is retained by the EventChannel (as its stream handler)
        // and by the ScanMethodHandler (as a stored property), so we don't
        // need a static reference. Previously kept around in a static var
        // that was never read — leaked across Flutter hot-restarts (H1).
        let sink = ScanEventSink()
        let handler = ScanMethodHandler(eventSink: sink)
        registrar.addMethodCallDelegate(handler, channel: methodChannel)
        eventChannel.setStreamHandler(sink)

        // Phase 04 / WIDGET-01 — register the camera-preview platform view
        // so the Dart `NsfwCameraView` can host an `AVCaptureVideoPreviewLayer`
        // backed by the same `AVCaptureSession` that `CameraSessionTask`
        // is feeding frames to. View-type id matches the Dart contract.
        let previewFactory = NsfwCameraPreviewFactory(messenger: registrar.messenger())
        registrar.register(previewFactory, withId: "nsfw_detect_ios/camera_preview")
    }

    // MARK: - Background scan (callable without a Flutter engine)

    /// Runs a gallery scan in a BGProcessingTask or similar background context.
    ///
    /// All work is performed on background threads. The completion handler is
    /// called on an arbitrary thread with `true` on success, `false` on error.
    ///
    /// Example usage from AppDelegate:
    /// ```swift
    /// NsfwDetectIosPlugin.performBackgroundGalleryScan { success in
    ///     task.setTaskCompleted(success: success)
    /// }
    /// ```
    @objc public static func performBackgroundGalleryScan(
        modelId: String = "falconsai_nsfw",
        completion: @escaping (Bool) -> Void
    ) {
        Task(priority: .utility) {
            do {
                let registry = ModelRegistry.shared

                // Download model if not yet on disk.
                if let desc = registry.descriptor(for: modelId),
                   desc.requiresDownload && !desc.isAvailable,
                   let resourceName = desc.bundleResourceName,
                   let urlString = desc.downloadUrl,
                   let url = URL(string: urlString) {
                    _ = try await ModelDownloadManager.shared.download(
                        modelId: modelId,
                        resourceName: resourceName,
                        from: url,
                        progress: { _ in }
                    )
                }

                // Compile / load model.
                _ = try await registry.engine(for: modelId)

                // Run scan — events go to a no-op sink (no Flutter engine in background).
                let config = ScanConfiguration(from: [
                    "modelId": modelId,
                    "confidenceThreshold": 0.7,
                    "includeVideos": false,
                    "includeLivePhotos": false,
                    "resumeFromCheckpoint": true,
                    "concurrency": 2,
                ])
                let noOpSink = ScanEventSink()  // sink is nil → emit() calls are no-ops
                let scan = ScanSessionTask(config: config, eventSink: noOpSink)
                await scan.start()
                completion(true)
            } catch {
                NSLog("[NSFW] Background scan failed: %@", error.localizedDescription)
                completion(false)
            }
        }
    }

    // MARK: - Migrations

    private static func runMigrations() {
        let migrationKey = "nsfw_plugin_migration_version"
        let targetVersion = 1
        let completed = UserDefaults.standard.integer(forKey: migrationKey)
        guard completed < targetVersion else { return }

        migrateV1RemoveNudeNet()
        UserDefaults.standard.set(targetVersion, forKey: migrationKey)
    }

    private static func migrateV1RemoveNudeNet() {
        let defaults = UserDefaults.standard
        let modelsDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("nsfw_models")

        let staleKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("nsfw_model_url_") && $0.lowercased().contains("nudenet")
        }

        for key in staleKeys {
            let resourceName = key.replacingOccurrences(of: "nsfw_model_url_", with: "")
            let modelDir = modelsDir.appendingPathComponent("\(resourceName).mlmodelc")
            try? FileManager.default.removeItem(at: modelDir)
            defaults.removeObject(forKey: key)
            NSLog("[NSFW] Migration v1: cleared stale NudeNet key '\(key)'")
        }
    }
}
