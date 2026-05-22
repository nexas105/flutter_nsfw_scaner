import CryptoKit
import Foundation
import os

/// Downloads and manages on-demand ML model files.
/// Models are stored in Application Support/nsfw_models/ and persist across launches.
final class ModelDownloadManager {

    // MARK: - Security policy
    //
    // Hard caps applied to every download. Defense-in-depth for hosts the
    // app integrator may not fully control (e.g. user-supplied URLs via
    // `setModelDownloadUrl`). Tuned wide enough for the largest bundled
    // descriptor (~150 MB Falconsai .mlmodelc.zip) plus headroom, tight
    // enough that a zip bomb or accidental 4 GB blob can't blow past the
    // user's free disk before we notice.
    static let maxDownloadBytes:    Int64  = 500_000_000
    static let maxExtractedBytes:   Int64  = 600_000_000
    static let maxArchiveEntries:   Int    = 4096
    static let maxCompressionRatio: Double = 200.0

    static let shared = ModelDownloadManager()
    private init() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    private let lock = OSAllocatedUnfairLock()
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
    ///
    /// - Parameter expectedSha256: when set, the downloaded archive's SHA-256
    ///   must match (lowercase hex) before extraction is attempted. Mismatch
    ///   deletes the temp file and throws `integrityMismatch`. Use this for
    ///   any URL the integrator does not fully control.
    func download(
        modelId: String,
        resourceName: String,
        from url: URL,
        expectedSha256: String? = nil,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Already downloaded?
        if let existing = localURL(for: resourceName) {
            progress(1.0)
            return existing
        }

        // Reject non-HTTPS up front. http:// would be silently downgrade-able
        // by anyone on the network path; file:// and friends bypass URLSession
        // streaming guarantees. Integrators with a genuine need for plaintext
        // can pre-stage models on disk via `setModelDownloadUrl` + manual
        // copy. (Not configurable yet — keep the door bolted by default.)
        guard url.scheme?.lowercased() == "https" else {
            throw ModelDownloadError.insecureScheme(url.scheme ?? "<none>")
        }

        // Already downloading? Reuse task.
        let existingOrNew: Task<URL, Error> = lock.withLock {
            if let existing = activeDownloads[modelId] { return existing }
            let task = Task<URL, Error> {
                // Yield once so the spawning code below has a chance to publish
                // this Task to `activeDownloads` before any cleanup can fire.
                // Without this, a synchronously-throwing performDownload would
                // run the defer before `activeDownloads[modelId] = task`,
                // permanently stranding the (now-completed) Task in the map (C9).
                await Task.yield()
                defer {
                    lock.withLock { _ = activeDownloads.removeValue(forKey: modelId) }
                }
                return try await performDownload(
                    resourceName: resourceName,
                    from: url,
                    expectedSha256: expectedSha256,
                    progress: progress
                )
            }
            activeDownloads[modelId] = task
            return task
        }
        return try await existingOrNew.value
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
        expectedSha256: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        NSLog("[NSFW] Downloading model: %@ from %@", resourceName, url.absoluteString)

        // Why this isn't using `session.download(from:delegate:)`:
        //
        // The iOS 15 async download API silently hangs under iOS 17/18 when
        // the URLSession is built with a session-level URLSessionDownloadDelegate
        // (progress reporter) AND a per-task delegate is also passed — the
        // continuation never resumes, progress callbacks fire normally on
        // the session delegate, but the await blocks forever. No error.
        //
        // The fallback that works everywhere: kick off a plain
        // `downloadTask`, race the session-level delegate's progress /
        // completion / failure against a CheckedThrowingContinuation, and
        // move the file out of the URLSession temp slot *inside the
        // delegate's didFinishDownloadingTo* before URLSession reclaims it.
        let callbackQueue = OperationQueue()
        callbackQueue.qualityOfService = .utility
        callbackQueue.maxConcurrentOperationCount = 1
        let delegate = DownloadDelegate(onProgress: progress,
                                        maxBytes: Self.maxDownloadBytes)
        let session = URLSession(configuration: .default,
                                 delegate: delegate,
                                 delegateQueue: callbackQueue)
        defer { session.invalidateAndCancel() }

        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.timeoutInterval = 120
            return r
        }()

        let (tempURL, response): (URL, URLResponse) = try await
            withTaskCancellationHandler { @Sendable [delegate, session, request] in
                try await withCheckedThrowingContinuation { cont in
                    delegate.completion = { result in
                        cont.resume(with: result)
                    }
                    let task = session.downloadTask(with: request)
                    delegate.attachTask(task)
                    task.resume()
                }
            } onCancel: { @Sendable [delegate] in
                delegate.cancel()
            }
        // URLSession moves `tempURL` out from under us once this scope ends —
        // copy to our own staging file so the post-download checks operate on
        // a stable path even if the call site retries.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModelDownloadError.httpError(code)
        }

        // Content-Length pre-check (defense-in-depth; the delegate also
        // enforces a hard cap on bytes actually received in case a server
        // lies about the header).
        if http.expectedContentLength > 0,
           http.expectedContentLength > Self.maxDownloadBytes {
            throw ModelDownloadError.tooLarge(http.expectedContentLength)
        }
        // Confirm what landed on disk respects the cap. The delegate
        // should have aborted earlier, but the file is the source of truth.
        let downloadedSize = (try? FileManager.default
            .attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if downloadedSize > Self.maxDownloadBytes {
            throw ModelDownloadError.tooLarge(downloadedSize)
        }
        if delegate.aborted {
            throw ModelDownloadError.tooLarge(downloadedSize)
        }
        if http.expectedContentLength > 0,
           downloadedSize != http.expectedContentLength {
            throw ModelDownloadError.incompleteDownload(
                expected: http.expectedContentLength, got: downloadedSize)
        }

        // Optional pinned-hash verification. Hashing 150 MB on a modern
        // iPhone is ~0.4 s — acceptable for a model fetch that already
        // takes seconds.
        if let pin = expectedSha256?.lowercased(), !pin.isEmpty {
            let actual = try Self.sha256Hex(of: tempURL)
            guard actual == pin else {
                throw ModelDownloadError.integrityMismatch(expected: pin, actual: actual)
            }
        }

        let destURL = modelsDirectory.appendingPathComponent("\(resourceName).mlmodelc")

        // Remove old version if exists
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        // Extract ZIP → .mlmodelc directory. The previous version fell back
        // to `moveItem(tempURL → destURL)` on extraction failure under the
        // theory the download might be "already an mlmodelc". That can't
        // work — .mlmodelc is a directory bundle, not a file, so the fallback
        // produced a file masquerading as a bundle that CoreML later refused
        // to load. Surface the real error instead.
        let extractDir = modelsDirectory.appendingPathComponent("_extract_\(resourceName)")
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try FileManager.default.removeItem(at: extractDir)
        }
        do {
            try ZipExtractor.extract(tempURL,
                                     to: extractDir,
                                     maxTotalBytes: Self.maxExtractedBytes,
                                     maxEntries: Self.maxArchiveEntries,
                                     maxCompressionRatio: Self.maxCompressionRatio)
        } catch {
            NSLog("[NSFW] ZIP extraction failed for %@: %@",
                  resourceName, String(describing: error))
            try? FileManager.default.removeItem(at: extractDir)
            throw ModelDownloadError.extractionFailed(error.localizedDescription)
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

    /// Stream-hash a file with SHA-256. 64 KB chunks — peak memory bounded.
    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 65_536)) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

/// Lifts `URLSessionDownloadTask` callbacks into a single-shot
/// `Result<(URL, URLResponse), Error>` continuation. Required because the
/// iOS 15 async `URLSession.download(from:delegate:)` API hangs under
/// iOS 17/18 when both a session-level delegate AND a per-task delegate
/// are wired — see comment in `performDownload`.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate,
                                       @unchecked Sendable {
    let onProgress: (Double) -> Void
    let maxBytes:   Int64
    /// Flipped to `true` when we cancel the task for exceeding `maxBytes`.
    /// `performDownload` checks this to distinguish a legitimate 200-byte
    /// download from one that was cut short by us.
    private(set) var aborted = false

    /// Single-shot continuation resolved on first completion / failure.
    /// Cleared after firing so subsequent delegate callbacks become no-ops.
    var completion: ((Result<(URL, URLResponse), Error>) -> Void)?

    private let lock = NSLock()
    private weak var task: URLSessionDownloadTask?

    init(onProgress: @escaping (Double) -> Void, maxBytes: Int64) {
        self.onProgress = onProgress
        self.maxBytes   = maxBytes
    }

    func attachTask(_ task: URLSessionDownloadTask) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func cancel() {
        lock.lock()
        let t = task
        lock.unlock()
        t?.cancel()
    }

    private func deliver(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        let cb = completion
        completion = nil
        lock.unlock()
        cb?(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes {
            // A lying / misconfigured server can advertise a small
            // Content-Length and stream gigabytes. Cap the actual bytes
            // received and cancel so URLSession unwinds.
            aborted = true
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(frac) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession deletes `location` as soon as this method returns, so
        // move it to a staging file in the system temp dir *here* — every
        // post-download check (size cap, SHA verification, extraction)
        // operates on the staged copy from here on.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("nsfw_dl_\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            deliver(.failure(error))
            return
        }
        guard let resp = downloadTask.response else {
            deliver(.failure(URLError(.badServerResponse)))
            return
        }
        deliver(.success((staged, resp)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Only fires for the error path or for graceful cancellation.
        // The success path is resolved earlier inside `didFinishDownloadingTo`.
        guard let error = error else { return }
        deliver(.failure(error))
    }
}

// MARK: - Errors

enum ModelDownloadError: Error, LocalizedError {
    case httpError(Int)
    case extractionFailed(String)
    case insecureScheme(String)
    case tooLarge(Int64)
    case incompleteDownload(expected: Int64, got: Int64)
    case integrityMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Model download failed (HTTP \(code))"
        case .extractionFailed(let detail):
            return "Failed to extract model archive: \(detail)"
        case .incompleteDownload(let expected, let got):
            return "Model download incomplete — expected \(expected) bytes, received \(got)."
        case .insecureScheme(let scheme):
            return "Refusing to download model over \(scheme)://. Use https://."
        case .tooLarge(let bytes):
            return "Model download exceeded the \(ModelDownloadManager.maxDownloadBytes)-byte cap (\(bytes) bytes)."
        case .integrityMismatch(let expected, let actual):
            return "Model archive SHA-256 mismatch — expected \(expected), got \(actual)."
        }
    }
}
