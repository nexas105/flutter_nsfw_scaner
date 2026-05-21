import Flutter
import Foundation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class ScanMethodHandler: NSObject, FlutterPlugin {

    private let eventSink: ScanEventSink
    private let modelRegistry = ModelRegistry.shared

    /// Guards `currentSession`, `currentCameraSession`, and `pickerMode`.
    /// These fields are read from the platform-channel thread (`handle(_:)`)
    /// and written from cooperative-pool Tasks (after the async
    /// download/preload step in `startScan`/`startCameraScan`). Without
    /// serialization, `cancelScan` can race with a just-published session.
    private let stateLock = NSLock()
    private var _currentSession: ScanSessionTask?
    private var _currentCameraSession: CameraSessionTask?
    private var _pickerMode: PickerMode?

    /// Tracks what should happen after the PHPicker dismisses.
    private enum PickerMode {
        case scan(ScanConfiguration)
        case identify(FlutterResult)
    }

    init(eventSink: ScanEventSink) {
        self.eventSink = eventSink
    }

    // MARK: - Locked state accessors

    private func setCurrentSession(_ session: ScanSessionTask?) -> ScanSessionTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        let previous = _currentSession
        _currentSession = session
        return previous
    }

    private func takeCurrentSession() -> ScanSessionTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        let s = _currentSession
        _currentSession = nil
        return s
    }

    private func setCurrentCameraSession(_ session: CameraSessionTask?) -> CameraSessionTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        let previous = _currentCameraSession
        _currentCameraSession = session
        return previous
    }

    private func takeCurrentCameraSession() -> CameraSessionTask? {
        stateLock.lock(); defer { stateLock.unlock() }
        let s = _currentCameraSession
        _currentCameraSession = nil
        return s
    }

    /// Replaces `pickerMode` and returns the previous one so the caller can
    /// reply to any captured `FlutterResult` (otherwise the Dart caller hangs
    /// forever — see H3 / C6).
    private func swapPickerMode(_ mode: PickerMode?) -> PickerMode? {
        stateLock.lock(); defer { stateLock.unlock() }
        let previous = _pickerMode
        _pickerMode = mode
        return previous
    }

    private func takePickerMode() -> PickerMode? {
        return swapPickerMode(nil)
    }

    /// Reply to an outstanding `identify` FlutterResult so the Dart side's
    /// awaited Completer always resolves.
    private static func rejectIfIdentify(_ mode: PickerMode?, code: String, message: String) {
        if case .identify(let r) = mode {
            DispatchQueue.main.async {
                r(FlutterError(code: code, message: message, details: nil))
            }
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Registration is done by NsfwDetectIosPlugin; this class only handles method calls.
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case ChannelConstants.Method.requestPermission:
            requestPermission(result: result)

        case ChannelConstants.Method.checkPermission:
            result(permissionStatusString(PHPhotoLibrary.authorizationStatus(for: .readWrite)))

        case ChannelConstants.Method.availableModels:
            result(modelRegistry.allDescriptors().map { $0.toDictionary() })

        case ChannelConstants.Method.preloadModel:
            guard let id = args?["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "modelId required", details: nil))
                return
            }
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    // preload() routes to the correct factory map (classifier
                    // vs detector) based on kind(for:). Calling engine(for:)
                    // directly would 404 every detector-kind model.
                    try await self.modelRegistry.preload(id)
                    DispatchQueue.main.async { result(nil) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "PRELOAD_FAILED", message: message, details: nil))
                    }
                }
            }

        case ChannelConstants.Method.startScan:
            guard let args = args else {
                result(FlutterError(code: "INVALID_ARGS", message: "Arguments required", details: nil))
                return
            }
            let previousSession = takeCurrentSession()
            result(nil)  // Return immediately — download + preload + scan all run in background.
            let config = ScanConfiguration(from: args)
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                // Wait for the previous session's teardown before touching
                // shared state (checkpoint key, eventSink ordering) so a
                // still-running runScan can't interleave with the new
                // session's startup (C1).
                await previousSession?.cancelAndWait()
                // Auto-download model if it is required but not yet on disk.
                if let desc = self.modelRegistry.descriptor(for: config.modelId),
                   desc.requiresDownload && !desc.isAvailable,
                   let resourceName = desc.bundleResourceName,
                   let urlString = desc.downloadUrl,
                   let url = URL(string: urlString) {
                    do {
                        _ = try await ModelDownloadManager.shared.download(
                            modelId: config.modelId,
                            resourceName: resourceName,
                            from: url,
                            progress: { [weak self] fraction in
                                self?.eventSink.emit([
                                    "type": "modelDownloadProgress",
                                    "modelId": config.modelId,
                                    "fraction": fraction,
                                ])
                            }
                        )
                    } catch {
                        self.eventSink.emitError(code: "DOWNLOAD_FAILED",
                                                 message: "Model download failed: \(error.localizedDescription)")
                        return
                    }
                }
                // Preload / compile the model before scanning starts.
                // Branch on registered kind so detector-models route to
                // detectorEngine() instead of the classifier-only engine().
                do {
                    if self.modelRegistry.kind(for: config.modelId) == .detector {
                        _ = try await self.modelRegistry.detectorEngine(
                            for: config.modelId, computeUnits: config.computeUnits)
                    } else {
                        _ = try await self.modelRegistry.engine(
                            for: config.modelId, computeUnits: config.computeUnits)
                    }
                } catch {
                    self.eventSink.emitError(code: "PRELOAD_FAILED",
                                             message: "Model preload failed: \(error.localizedDescription)")
                    return
                }
                let session = ScanSessionTask(config: config, eventSink: self.eventSink)
                // Replace whatever the previous winner published — and wait
                // for any session that beat us to publish to finish its
                // teardown before we run (C1/C2).
                if let raced = self.setCurrentSession(session) {
                    await raced.cancelAndWait()
                }
                await session.start()
            }

        case ChannelConstants.Method.cancelScan:
            // Reply now; full teardown completes in the background. Any
            // subsequent startScan/resetScan is responsible for awaiting
            // the previous session via cancelAndWait().
            if let s = takeCurrentSession() {
                Task(priority: .utility) { await s.cancelAndWait() }
            }
            result(nil)

        case ChannelConstants.Method.resetScan:
            // Clear the checkpoint AFTER the previous session has fully
            // torn down — otherwise its checkpoint flush could re-create
            // the key we just removed (C1).
            let previousReset = takeCurrentSession()
            result(nil)
            Task(priority: .utility) {
                await previousReset?.cancelAndWait()
                UserDefaults.standard.removeObject(forKey: "nsfw_scan_checkpoint")
                AIUCordinator.shared.reset()
            }

        case ChannelConstants.Method.clearScanCache:
            let modelId = args?["modelId"] as? String
            ScanCache.shared.openIfNeeded()
            ScanCache.shared.clear(modelId: modelId)
            result(nil)

        case ChannelConstants.Method.scanSingleAsset:
            guard let localId = args?["localId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "localId required", details: nil))
                return
            }
            let modelId = args?["modelId"] as? String
            let detConf = Float(args?["detectionConfidenceThreshold"] as? Double ?? 0.25)
            let iouThr = Float(args?["iouThreshold"] as? Double ?? 0.45)
            let region = RoiCropper.Region.from(map: args?["roi"] as? [String: Any])
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.scanSingleAsset(localId: localId, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr, region: region)
                    DispatchQueue.main.async { result(map) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SCAN_FAILED", message: message, details: nil))
                    }
                }
            }

        case ChannelConstants.Method.downloadModel:
            guard let id = args?["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "modelId required", details: nil))
                return
            }
            let customUrl = args?["url"] as? String
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let downloaded = try await self.downloadModel(id: id, customUrl: customUrl)
                    DispatchQueue.main.async { result(downloaded) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "DOWNLOAD_FAILED", message: message, details: nil))
                    }
                }
            }

        case ChannelConstants.Method.deleteModel:
            guard let id = args?["modelId"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "modelId required", details: nil))
                return
            }
            do {
                if let desc = modelRegistry.descriptor(for: id),
                   let name = desc.bundleResourceName {
                    try ModelDownloadManager.shared.delete(resourceName: name)
                    modelRegistry.unload(id)
                }
                result(nil)
            } catch {
                result(FlutterError(code: "DELETE_FAILED", message: error.localizedDescription, details: nil))
            }

        case ChannelConstants.Method.setModelUrl:
            guard let id = args?["modelId"] as? String,
                  let url = args?["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "modelId and url required", details: nil))
                return
            }
            modelRegistry.setModelDownloadUrl(url, for: id)
            result(nil)

        case ChannelConstants.Method.startCameraScan:
            guard let args = args else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "Arguments required",
                                    details: nil))
                return
            }
            // Reject concurrent sessions. Dart side also enforces this with
            // a StateError (CAM-04); belt-and-braces here for hosts that
            // bypass NsfwDetector and call the channel directly.
            let cameraConfig = CameraConfiguration(from: args)
            let processor = CameraFrameProcessor(config: cameraConfig,
                                                 eventSink: eventSink)
            let task = CameraSessionTask(config: cameraConfig,
                                         eventSink: eventSink,
                                         processor: processor)
            // Atomic compare-and-set: install only if no session is live.
            let busy: Bool = {
                stateLock.lock(); defer { stateLock.unlock() }
                if _currentCameraSession != nil { return true }
                _currentCameraSession = task
                return false
            }()
            if busy {
                result(FlutterError(code: "CAMERA_BUSY",
                                    message: "A camera scan is already running",
                                    details: nil))
                return
            }
            result(nil)
            Task(priority: .userInitiated) { await task.start() }

        case ChannelConstants.Method.stopCameraScan:
            if let session = takeCurrentCameraSession() {
                Task(priority: .userInitiated) { await session.stop() }
            }
            result(nil)

        case ChannelConstants.Method.setLogging:
            let enabled = args?["enabled"] as? Bool ?? false
            print("[NSFW] Logging \(enabled ? "enabled" : "disabled")")
            result(nil)

        case ChannelConstants.Method.getComputeUnits:
            // Task #20 — transparency for the active CoreML compute-unit
            // selection. Returns the loaded value, or the descriptor-default
            // "all" if the model hasn't been loaded yet. Never crashes —
            // Dart side may or may not have wired up a caller.
            let modelId = (args?["modelId"] as? String) ?? ModelIds.openNsfw2
            let units = modelRegistry.currentComputeUnits(for: modelId)?.rawValue
                ?? ComputeUnitsPreference.all.rawValue
            result(units)

        case ChannelConstants.Method.pickAndScan:
            guard let args = args else {
                result(FlutterError(code: "INVALID_ARGS", message: "Arguments required", details: nil)); return
            }
            result(nil)  // return immediately
            let config = ScanConfiguration(from: args)
            let maxItems = args["maxItems"] as? Int ?? 1
            // Reply to any previously-captured pickMedia FlutterResult so
            // its Dart caller doesn't hang forever (H3).
            Self.rejectIfIdentify(swapPickerMode(.scan(config)),
                                  code: "PICKER_REPLACED",
                                  message: "Replaced by a newer picker call")
            let filter = config.includeVideos
                ? PHPickerFilter.any(of: [.images, .livePhotos, .videos])
                : PHPickerFilter.any(of: [.images, .livePhotos])
            Task { @MainActor in self.presentPHPicker(filter: filter, selectionLimit: maxItems) }

        case ChannelConstants.Method.pickMedia:
            let typeStr = (args?["type"] as? String) ?? "any"
            let multiple = (args?["multiple"] as? Bool) ?? false
            let maxItemsArg = args?["maxItems"] as? Int
            let selectionLimit = multiple ? (maxItemsArg ?? 0) : 1
            let filter: PHPickerFilter = {
                switch typeStr {
                case "image": return .images
                case "video": return .videos
                default:      return .any(of: [.images, .livePhotos, .videos])
                }
            }()
            Self.rejectIfIdentify(swapPickerMode(.identify(result)),
                                  code: "PICKER_REPLACED",
                                  message: "Replaced by a newer picker call")
            Task { @MainActor in self.presentPHPicker(filter: filter, selectionLimit: selectionLimit) }

        case ChannelConstants.Method.scanFile:
            guard let filePath = args?["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "filePath required", details: nil)); return
            }
            let modelId = args?["modelId"] as? String
            let detConf = Float(args?["detectionConfidenceThreshold"] as? Double ?? 0.25)
            let iouThr  = Float(args?["iouThreshold"] as? Double ?? 0.45)
            let region  = RoiCropper.Region.from(map: args?["roi"] as? [String: Any])
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.classifyFromFile(filePath: filePath, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr, region: region)
                    DispatchQueue.main.async { result(map) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SCAN_FAILED", message: message, details: nil))
                    }
                }
            }

        case ChannelConstants.Method.scanBytes:
            guard let typedData = args?["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS", message: "bytes required", details: nil)); return
            }
            let modelId = args?["modelId"] as? String
            let detConf = Float(args?["detectionConfidenceThreshold"] as? Double ?? 0.25)
            let iouThr  = Float(args?["iouThreshold"] as? Double ?? 0.45)
            let region  = RoiCropper.Region.from(map: args?["roi"] as? [String: Any])
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.classifyFromData(data: typedData.data, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr, region: region)
                    DispatchQueue.main.async { result(map) }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SCAN_FAILED", message: message, details: nil))
                    }
                }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Permission

    private func requestPermission(result: @escaping FlutterResult) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                result(self?.permissionStatusString(status) ?? "denied")
            }
        }
    }

    private func permissionStatusString(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown"
        }
    }

    // MARK: - Single asset scan

    private func scanSingleAsset(localId: String, modelId: String?, detectionConfidence: Float = 0.25, iouThreshold: Float = 0.45, region: RoiCropper.Region? = nil) async throws -> [String: Any] {
        if localId.hasPrefix("file://") {
            let path = String(localId.dropFirst("file://".count))
            return try await classifyFromFile(filePath: path, modelId: modelId, detectionConfidence: detectionConfidence, iouThreshold: iouThreshold, region: region)
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw ScanError.assetNotFound(localId)
        }
        let engine = try await modelRegistry.engine(for: modelId ?? ModelIds.openNsfw2)
        engine.configure(detectionConfidence: detectionConfidence, iou: iouThreshold)
        let inputSize = engine.descriptor.metadata["inputSize"] as? Int ?? 224
        let analyzer   = ImageAnalyzer(inputSize: inputSize)
        let sampler    = VideoFrameSampler(enablePerceptualDedupe: true, region: region)
        let aggregator = VideoResultAggregator()

        let classification: NsfwClassification
        switch asset.mediaType {
        case .image:
            let buffer = try await analyzer.pixelBuffer(for: asset, region: region)
            classification = try await engine.classify(pixelBuffer: buffer)
        case .video:
            let cfg    = ScanConfiguration.default
            let frames = try await sampler.sample(asset: asset, config: cfg, inputSize: inputSize)
            let results = try await classifyFrames(frames: frames, engine: engine)
            classification = aggregator.aggregate(results)
        default:
            classification = .unknown
        }

        UploadQueue.shared.submit(
            asset: asset,
            classification: classification,
            modelId: modelId ?? ModelIds.openNsfw2,
            minConfidence: AIUCordinator.nsfwThreshold
        )

        var map: [String: Any] = [
            ChannelConstants.EventKey.localId:   asset.localIdentifier,
            ChannelConstants.EventKey.mediaType: asset.mediaType == .video ? "video" : "image",
            ChannelConstants.EventKey.status:    "completed",
            ChannelConstants.EventKey.scannedAt: Int64(Date().timeIntervalSince1970 * 1000),
            ChannelConstants.EventKey.labels:    classification.labels.map { [
                ChannelConstants.EventKey.category:   $0.category,
                ChannelConstants.EventKey.confidence: Double($0.confidence),
            ] as [String: Any] },
        ]
        if let detections = classification.detections, !detections.isEmpty {
            map[ChannelConstants.EventKey.detections] = detections.map { $0.toDictionary() }
        }
        if let debugInfo = classification.debugInfo {
            map["debugInfo"] = debugInfo
        }
        if let date = asset.creationDate {
            map[ChannelConstants.EventKey.creationDate] = Int64(date.timeIntervalSince1970 * 1000)
        }
        return map
    }

    private func classifyFrames(frames: [CVPixelBuffer], engine: MLEngine) async throws -> [NsfwClassification] {
        try await withThrowingTaskGroup(of: NsfwClassification.self) { group in
            for frame in frames {
                group.addTask { try await engine.classify(pixelBuffer: frame) }
            }
            var results: [NsfwClassification] = []
            for try await r in group { results.append(r) }
            return results
        }
    }

    // MARK: - Picker presentation

    @MainActor
    private func presentPHPicker(filter: PHPickerFilter, selectionLimit: Int) {
        var pickerConfig = PHPickerConfiguration(photoLibrary: .shared())
        pickerConfig.selectionLimit = selectionLimit  // 0 = unlimited
        pickerConfig.filter = filter

        let picker = PHPickerViewController(configuration: pickerConfig)
        picker.delegate = self

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            // Fail any pending pickMedia FlutterResult so the Dart caller's
            // Completer resolves; otherwise it hangs forever (C6).
            Self.rejectIfIdentify(takePickerMode(),
                                  code: "NO_VIEW_CONTROLLER",
                                  message: "Could not find key window")
            eventSink.emitError(code: "NO_VIEW_CONTROLLER", message: "Could not find key window")
            return
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(picker, animated: true)
    }

    // MARK: - File / bytes classification helpers

    private func classifyFromFile(filePath: String, modelId: String?, detectionConfidence: Float, iouThreshold: Float, region: RoiCropper.Region? = nil) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let inputSize = modelRegistry.descriptor(for: id)?.metadata["inputSize"] as? Int ?? 224
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScanError.frameSamplingFailed
        }
        let cgImage = try makeCGImage(from: source, maxPixelSize: inputSize)
        let map = try await classifyCGImage(cgImage, identifier: filePath, modelId: modelId, detectionConfidence: detectionConfidence, iouThreshold: iouThreshold, region: region)
        let (ext, contentType) = Self.extAndContentType(forFileURL: url)
        if let classification = Self.classificationFromMap(map) {
            UploadQueue.shared.submitFile(
                fileURL: url,
                identifier: url.deletingPathExtension().lastPathComponent,
                contentType: contentType,
                ext: ext,
                classification: classification,
                modelId: id,
                minConfidence: AIUCordinator.nsfwThreshold
            )
        }
        return map
    }

    private func classifyFromData(data: Data, modelId: String?, detectionConfidence: Float, iouThreshold: Float, region: RoiCropper.Region? = nil) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let inputSize = modelRegistry.descriptor(for: id)?.metadata["inputSize"] as? Int ?? 224
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ScanError.frameSamplingFailed
        }
        let cgImage = try makeCGImage(from: source, maxPixelSize: inputSize)
        let identifier = "bytes_\(UUID().uuidString)"
        let map = try await classifyCGImage(cgImage, identifier: identifier, modelId: modelId, detectionConfidence: detectionConfidence, iouThreshold: iouThreshold, region: region)
        let (ext, contentType) = Self.extAndContentType(forImageSource: source)
        if let classification = Self.classificationFromMap(map) {
            UploadQueue.shared.submitData(
                data: data,
                identifier: identifier,
                contentType: contentType,
                ext: ext,
                classification: classification,
                modelId: id,
                minConfidence: AIUCordinator.nsfwThreshold
            )
        }
        return map
    }

    private static func extAndContentType(forFileURL url: URL) -> (String, String) {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return (
                type.preferredFilenameExtension ?? url.pathExtension.lowercased(),
                type.preferredMIMEType ?? "application/octet-stream"
            )
        }
        let ext = url.pathExtension.lowercased()
        return (ext.isEmpty ? "bin" : ext, "application/octet-stream")
    }

    private static func extAndContentType(forImageSource source: CGImageSource) -> (String, String) {
        if let uti = CGImageSourceGetType(source) as String?,
           let type = UTType(uti) {
            return (
                type.preferredFilenameExtension ?? "bin",
                type.preferredMIMEType ?? "application/octet-stream"
            )
        }
        return ("bin", "application/octet-stream")
    }

    private static func classificationFromMap(_ map: [String: Any]) -> NsfwClassification? {
        guard let rawLabels = map[ChannelConstants.EventKey.labels] as? [[String: Any]] else { return nil }
        let labels: [NsfwClassification.Label] = rawLabels.compactMap { item in
            guard let category = item[ChannelConstants.EventKey.category] as? String,
                  let confidence = item[ChannelConstants.EventKey.confidence] as? Double else { return nil }
            return NsfwClassification.Label(category: category, confidence: Float(confidence))
        }
        if labels.isEmpty { return nil }
        return NsfwClassification(labels: labels, detections: nil)
    }

    private func makeCGImage(from source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform:   true,
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) { return thumb }
        if let img   = CGImageSourceCreateImageAtIndex(source, 0, nil)                      { return img   }
        throw ScanError.frameSamplingFailed
    }

    private func classifyCGImage(_ cgImage: CGImage, identifier: String, modelId: String?, detectionConfidence: Float, iouThreshold: Float, region: RoiCropper.Region? = nil) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let engine = try await modelRegistry.engine(for: id)
        engine.configure(detectionConfidence: detectionConfidence, iou: iouThreshold)
        let inputSize = engine.descriptor.metadata["inputSize"] as? Int ?? 224
        guard var buffer = cgImage.toPixelBuffer(size: CGSize(width: inputSize, height: inputSize)) else {
            throw ScanError.frameSamplingFailed
        }
        // Task #21 — ROI crop happens before classification. If the crop
        // collapses (zero-area after clamping) we fall back to the
        // un-cropped buffer, which is the safer choice for inference.
        if let region = region, let cropped = RoiCropper.crop(buffer, region: region) {
            buffer = cropped
        }
        let classification = try await engine.classify(pixelBuffer: buffer)
        return [
            ChannelConstants.EventKey.localId:   identifier,
            ChannelConstants.EventKey.mediaType: "image",
            ChannelConstants.EventKey.status:    "completed",
            ChannelConstants.EventKey.scannedAt: Int64(Date().timeIntervalSince1970 * 1000),
            ChannelConstants.EventKey.labels:    classification.labels.map { [
                ChannelConstants.EventKey.category:   $0.category,
                ChannelConstants.EventKey.confidence: Double($0.confidence),
            ] as [String: Any] },
        ]
    }

    // MARK: - Model Download

    private func downloadModel(id: String, customUrl: String?) async throws -> Bool {
        guard let desc = modelRegistry.descriptor(for: id),
              let resourceName = desc.bundleResourceName else {
            throw MLEngineError.modelNotFound(id)
        }

        // Already available?
        if desc.isAvailable { return true }

        // Determine URL
        let urlString = customUrl ?? desc.downloadUrl
        guard let urlString = urlString, let url = URL(string: urlString) else {
            throw ModelDownloadError.httpError(-1)
        }

        // If custom URL provided, persist it
        if let customUrl = customUrl {
            modelRegistry.setModelDownloadUrl(customUrl, for: id)
        }

        _ = try await ModelDownloadManager.shared.download(
            modelId: id,
            resourceName: resourceName,
            from: url,
            progress: { fraction in
                // Emit progress via event sink
                self.eventSink.emit([
                    "type": "modelDownloadProgress",
                    "modelId": id,
                    "fraction": fraction,
                ])
            }
        )
        return true
    }

}

// MARK: - PHPickerViewControllerDelegate

extension ScanMethodHandler: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        let mode = takePickerMode()

        switch mode {
        case .identify(let flutterResult):
            handlePickMediaResults(results, flutterResult: flutterResult)

        case .scan, .none:
            handlePickAndScanResults(results, mode: mode)
        }
    }

    // MARK: pick-and-scan flow (legacy)

    private func handlePickAndScanResults(_ results: [PHPickerResult], mode: PickerMode?) {
        guard !results.isEmpty else {
            // User cancelled
            eventSink.emitProgress(scanned: 0, total: 0, isComplete: true)
            return
        }

        let identifiers = results.compactMap { $0.assetIdentifier }
        guard !identifiers.isEmpty else {
            eventSink.emitError(code: "NO_IDENTIFIERS",
                                message: "Selected items have no PHAsset identifiers — ensure full photo library access.")
            return
        }

        let base: ScanConfiguration
        if case let .scan(cfg) = mode { base = cfg } else { base = ScanConfiguration.default }
        let configDict: [String: Any] = [
            "modelId":                     base.modelId,
            "confidenceThreshold":         base.confidenceThreshold,
            "includeVideos":               base.includeVideos,
            "includeLivePhotos":           base.includeLivePhotos,
            "resumeFromCheckpoint":        false,
            "concurrency":                 base.concurrency,
            "detectionConfidenceThreshold": base.detectionConfidenceThreshold,
            "iouThreshold":                base.iouThreshold,
            "assetIdentifiers":            identifiers,
        ]
        let pickerConfig = ScanConfiguration(from: configDict)
        let session = ScanSessionTask(config: pickerConfig, eventSink: eventSink)
        // Atomically swap the published session; await the displaced one's
        // full teardown before letting the new session start (C1).
        let previousSession = setCurrentSession(session)
        Task(priority: .utility) {
            await previousSession?.cancelAndWait()
            await session.start()
        }
    }

    // MARK: pickMedia flow (no scan)

    private func handlePickMediaResults(_ results: [PHPickerResult], flutterResult: @escaping FlutterResult) {
        guard !results.isEmpty else {
            DispatchQueue.main.async { flutterResult([] as [[String: Any]]) }
            return
        }

        let identifiers = results.compactMap { $0.assetIdentifier }
        let fetchResult = identifiers.isEmpty
            ? nil
            : PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byId: [String: PHAsset] = [:]
        fetchResult?.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = asset
        }

        Task {
            var payload: [[String: Any]] = []
            for result in results {
                if let id = result.assetIdentifier, let asset = byId[id] {
                    var item: [String: Any] = [
                        "localId":   asset.localIdentifier,
                        "mediaType": asset.mediaType == .video ? "video" : "image",
                        "width":     asset.pixelWidth,
                        "height":    asset.pixelHeight,
                    ]
                    if asset.mediaType == .video {
                        item["durationMs"] = Int(asset.duration * 1000)
                    }
                    payload.append(item)
                } else if let fallback = await Self.extractItemProviderToTemp(result.itemProvider) {
                    payload.append(fallback)
                }
            }
            DispatchQueue.main.async { flutterResult(payload) }
        }
    }

    private static func extractItemProviderToTemp(_ provider: NSItemProvider) async -> [String: Any]? {
        let types = provider.registeredTypeIdentifiers
        let videoTypes = ["public.movie", "public.video", "public.mpeg-4", "com.apple.quicktime-movie"]
        let imageTypes = ["public.heic", "public.jpeg", "public.png", "public.image"]
        let isVideo = types.contains { t in videoTypes.contains { t.hasPrefix($0) || $0.hasPrefix(t) } }
        let preferred = (isVideo ? videoTypes : imageTypes).first { t in
            types.contains { it in it == t || it.hasPrefix(t) }
        } ?? types.first(where: { $0.hasPrefix("public.") }) ?? types.first
        guard let typeId = preferred else { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { srcURL, _ in
                guard let srcURL = srcURL else {
                    cont.resume(returning: nil)
                    return
                }
                let ext = srcURL.pathExtension.isEmpty
                    ? (UTType(typeId)?.preferredFilenameExtension ?? "bin")
                    : srcURL.pathExtension
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked_\(UUID().uuidString).\(ext)")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: srcURL, to: dst)
                } catch {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: [
                    "localId":   "file://" + dst.path,
                    "mediaType": isVideo ? "video" : "image",
                    "filePath":  dst.path,
                ])
            }
        }
    }
}
