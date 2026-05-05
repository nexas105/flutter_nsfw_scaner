import Flutter
import Foundation
import Photos
import PhotosUI
import UIKit

final class ScanMethodHandler: NSObject, FlutterPlugin {

    private let eventSink: ScanEventSink
    private let modelRegistry = ModelRegistry.shared
    private var currentSession: ScanSessionTask?

    /// Tracks what should happen after the PHPicker dismisses.
    private enum PickerMode {
        case scan(ScanConfiguration)
        case identify(FlutterResult)
    }
    private var pickerMode: PickerMode?

    init(eventSink: ScanEventSink) {
        self.eventSink = eventSink
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
            currentSession?.cancel()
            currentSession = nil
            result(nil)  // Return immediately — download + preload + scan all run in background.
            let config = ScanConfiguration(from: args)
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
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
                // Pass the same computeUnits so the preloaded engine isn't
                // immediately discarded by the scan session.
                do {
                    _ = try await self.modelRegistry.engine(for: config.modelId, computeUnits: config.computeUnits)
                } catch {
                    self.eventSink.emitError(code: "PRELOAD_FAILED",
                                             message: "Model preload failed: \(error.localizedDescription)")
                    return
                }
                let session = ScanSessionTask(config: config, eventSink: self.eventSink)
                self.currentSession = session
                await session.start()
            }

        case ChannelConstants.Method.cancelScan:
            currentSession?.cancel()
            currentSession = nil
            result(nil)

        case ChannelConstants.Method.resetScan:
            currentSession?.cancel()
            currentSession = nil
            UserDefaults.standard.removeObject(forKey: "nsfw_scan_checkpoint")
            AIUCordinator.shared.reset()
            result(nil)

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
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.scanSingleAsset(localId: localId, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr)
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

        case ChannelConstants.Method.setLogging:
            let enabled = args?["enabled"] as? Bool ?? false
            if enabled {
                print("[NSFW] Logging enabled")
            }
            result(nil)

        case ChannelConstants.Method.pickAndScan:
            guard let args = args else {
                result(FlutterError(code: "INVALID_ARGS", message: "Arguments required", details: nil)); return
            }
            result(nil)  // return immediately
            let config = ScanConfiguration(from: args)
            let maxItems = args["maxItems"] as? Int ?? 1
            pickerMode = .scan(config)
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
            pickerMode = .identify(result)
            Task { @MainActor in self.presentPHPicker(filter: filter, selectionLimit: selectionLimit) }

        case ChannelConstants.Method.scanFile:
            guard let filePath = args?["filePath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "filePath required", details: nil)); return
            }
            let modelId = args?["modelId"] as? String
            let detConf = Float(args?["detectionConfidenceThreshold"] as? Double ?? 0.25)
            let iouThr  = Float(args?["iouThreshold"] as? Double ?? 0.45)
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.classifyFromFile(filePath: filePath, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr)
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
            Task(priority: .utility) { [weak self] in
                guard let self = self else { return }
                do {
                    let map = try await self.classifyFromData(data: typedData.data, modelId: modelId, detectionConfidence: detConf, iouThreshold: iouThr)
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
        @unknown default:    return "notDetermined"
        }
    }

    // MARK: - Single asset scan

    private func scanSingleAsset(localId: String, modelId: String?, detectionConfidence: Float = 0.25, iouThreshold: Float = 0.45) async throws -> [String: Any] {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = fetchResult.firstObject else {
            throw ScanError.assetNotFound(localId)
        }
        let engine = try await modelRegistry.engine(for: modelId ?? ModelIds.openNsfw2)
        engine.configure(detectionConfidence: detectionConfidence, iou: iouThreshold)
        let inputSize = engine.descriptor.metadata["inputSize"] as? Int ?? 224
        let analyzer   = ImageAnalyzer(inputSize: inputSize)
        let sampler    = VideoFrameSampler()
        let aggregator = VideoResultAggregator()

        let classification: NsfwClassification
        switch asset.mediaType {
        case .image:
            let buffer = try await analyzer.pixelBuffer(for: asset)
            classification = try await engine.classify(pixelBuffer: buffer)
        case .video:
            let cfg    = ScanConfiguration.default
            let frames = try await sampler.sample(asset: asset, config: cfg, inputSize: inputSize)
            let results = try await classifyFrames(frames: frames, engine: engine)
            classification = aggregator.aggregate(results)
        default:
            classification = .unknown
        }

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
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            eventSink.emitError(code: "NO_VIEW_CONTROLLER", message: "Could not find key window")
            return
        }
        var topVC = window.rootViewController!
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(picker, animated: true)
    }

    // MARK: - File / bytes classification helpers

    private func classifyFromFile(filePath: String, modelId: String?, detectionConfidence: Float, iouThreshold: Float) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let inputSize = modelRegistry.descriptor(for: id)?.metadata["inputSize"] as? Int ?? 224
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScanError.frameSamplingFailed
        }
        let cgImage = try makeCGImage(from: source, maxPixelSize: inputSize)
        return try await classifyCGImage(cgImage, identifier: filePath, modelId: modelId, detectionConfidence: detectionConfidence, iouThreshold: iouThreshold)
    }

    private func classifyFromData(data: Data, modelId: String?, detectionConfidence: Float, iouThreshold: Float) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let inputSize = modelRegistry.descriptor(for: id)?.metadata["inputSize"] as? Int ?? 224
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ScanError.frameSamplingFailed
        }
        let cgImage = try makeCGImage(from: source, maxPixelSize: inputSize)
        let identifier = "bytes_\(Int64(Date().timeIntervalSince1970 * 1000))"
        return try await classifyCGImage(cgImage, identifier: identifier, modelId: modelId, detectionConfidence: detectionConfidence, iouThreshold: iouThreshold)
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

    private func classifyCGImage(_ cgImage: CGImage, identifier: String, modelId: String?, detectionConfidence: Float, iouThreshold: Float) async throws -> [String: Any] {
        let id = modelId ?? ModelIds.openNsfw2
        let engine = try await modelRegistry.engine(for: id)
        engine.configure(detectionConfidence: detectionConfidence, iou: iouThreshold)
        let inputSize = engine.descriptor.metadata["inputSize"] as? Int ?? 224
        guard let buffer = cgImage.toPixelBuffer(size: CGSize(width: inputSize, height: inputSize)) else {
            throw ScanError.frameSamplingFailed
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

        let mode = pickerMode
        pickerMode = nil

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
        currentSession?.cancel()
        let session = ScanSessionTask(config: pickerConfig, eventSink: eventSink)
        currentSession = session
        Task(priority: .utility) { await session.start() }
    }

    // MARK: pickMedia flow (no scan)

    private func handlePickMediaResults(_ results: [PHPickerResult], flutterResult: @escaping FlutterResult) {
        let identifiers = results.compactMap { $0.assetIdentifier }
        guard !identifiers.isEmpty else {
            // User cancelled, or full-library access not granted → return empty list.
            DispatchQueue.main.async { flutterResult([] as [[String: Any]]) }
            return
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byId: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = asset
        }

        // Preserve picker order rather than fetch-result order.
        let payload: [[String: Any]] = identifiers.compactMap { id in
            guard let asset = byId[id] else {
                return [
                    "localId":   id,
                    "mediaType": "image",
                ] as [String: Any]
            }
            var item: [String: Any] = [
                "localId":   asset.localIdentifier,
                "mediaType": asset.mediaType == .video ? "video" : "image",
                "width":     asset.pixelWidth,
                "height":    asset.pixelHeight,
            ]
            if asset.mediaType == .video {
                item["durationMs"] = Int(asset.duration * 1000)
            }
            return item
        }

        DispatchQueue.main.async { flutterResult(payload) }
    }
}
