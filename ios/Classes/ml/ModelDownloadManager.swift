import Foundation

/// Downloads and manages on-demand ML model files.
/// Models are stored in Application Support/nsfw_models/ and persist across launches.
final class ModelDownloadManager {

    static let shared = ModelDownloadManager()
    private init() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private let lock = NSLock()
    private var activeDownloads: [String: Task<URL, Error>] = [:]

    /// Directory where downloaded models are stored
    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("nsfw_models", isDirectory: true)
    }

    /// Check if a model has been downloaded
    func isDownloaded(resourceName: String) -> Bool {
        let modelPath = modelsDirectory.appendingPathComponent("\(resourceName).mlmodelc")
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Get the local URL of a downloaded model (nil if not downloaded)
    func localURL(for resourceName: String) -> URL? {
        let modelPath = modelsDirectory.appendingPathComponent("\(resourceName).mlmodelc")
        if FileManager.default.fileExists(atPath: modelPath.path) {
            return modelPath
        }
        return nil
    }

    /// Download a model .zip from a URL, extract .mlmodelc, store locally.
    /// Progress is reported via the callback (0.0 to 1.0).
    func download(
        modelId: String,
        resourceName: String,
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Already downloaded?
        if let existing = localURL(for: resourceName) {
            progress(1.0)
            return existing
        }

        // Already downloading? Reuse task.
        lock.lock()
        if let existing = activeDownloads[modelId] {
            lock.unlock()
            return try await existing.value
        }

        let task = Task<URL, Error> {
            // Yield once so the spawning code below has a chance to publish
            // this Task to `activeDownloads` before any cleanup can fire.
            // Without this, a synchronously-throwing performDownload would
            // run the defer before `activeDownloads[modelId] = task`,
            // permanently stranding the (now-completed) Task in the map (C9).
            await Task.yield()
            defer {
                lock.lock()
                activeDownloads.removeValue(forKey: modelId)
                lock.unlock()
            }
            return try await performDownload(resourceName: resourceName, from: url, progress: progress)
        }
        activeDownloads[modelId] = task
        lock.unlock()

        return try await task.value
    }

    /// Delete a downloaded model to free space
    func delete(resourceName: String) throws {
        let modelPath = modelsDirectory.appendingPathComponent("\(resourceName).mlmodelc")
        if FileManager.default.fileExists(atPath: modelPath.path) {
            try FileManager.default.removeItem(at: modelPath)
            NSLog("[NSFW] Deleted downloaded model: %@", resourceName)
        }
    }

    /// Total disk usage of downloaded models in bytes
    func downloadedSizeBytes() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil
        ) else { return 0 }

        var total: Int64 = 0
        for url in contents {
            total += directorySize(url)
        }
        return total
    }

    // MARK: - Private

    private func performDownload(
        resourceName: String,
        from url: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        NSLog("[NSFW] Downloading model: %@ from %@", resourceName, url.absoluteString)

        let delegate = DownloadDelegate(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (tempURL, response) = try await session.download(from: url, delegate: delegate)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelDownloadError.httpError(code)
        }

        let destURL = modelsDirectory.appendingPathComponent("\(resourceName).mlmodelc")

        // Remove old version if exists
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        // Extract ZIP → .mlmodelc directory
        let extractDir = modelsDirectory.appendingPathComponent("_extract_\(resourceName)")
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try FileManager.default.removeItem(at: extractDir)
        }

        do {
            try ZipExtractor.extract(tempURL, to: extractDir)
        } catch {
            NSLog("[NSFW] ZIP extraction failed: %@, trying as raw mlmodelc", error.localizedDescription)
            // Maybe it's already an mlmodelc directory (not zipped)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
            progress(1.0)
            return destURL
        }

        // Find the .mlmodelc inside the extracted directory
        if let found = try findMLModelC(in: extractDir) {
            try FileManager.default.moveItem(at: found, to: destURL)
        } else {
            // The extracted content IS the model (flat extraction)
            try FileManager.default.moveItem(at: extractDir, to: destURL)
        }

        // Cleanup
        try? FileManager.default.removeItem(at: extractDir)

        progress(1.0)
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(directorySize(destURL)), countStyle: .file)
        NSLog("[NSFW] Model ready: %@ (%@)", resourceName, sizeStr)
        return destURL
    }

    private func findMLModelC(in directory: URL) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Direct .mlmodelc
        for url in contents where url.pathExtension == "mlmodelc" {
            return url
        }
        // One level deeper (e.g., zip contains a folder with the model)
        for url in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let subContents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for sub in subContents where sub.pathExtension == "mlmodelc" {
                    return sub
                }
            }
        }
        return nil
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - URLSession Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(frac) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by async download(from:)
    }
}

// MARK: - Errors

enum ModelDownloadError: Error, LocalizedError {
    case httpError(Int)
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Model download failed (HTTP \(code))"
        case .extractionFailed: return "Failed to extract model archive"
        }
    }
}
