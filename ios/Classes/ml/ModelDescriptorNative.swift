import Foundation

struct ModelDescriptorNative {
    let id:                 String
    let displayName:        String
    let description:        String?
    let version:            String?
    let bundleResourceName: String?   // e.g. "OpenNSFW2" (without .mlmodelc extension)
    let metadata:           [String: Any]

    /// If nil, model is bundled in the app. If set, model must be downloaded first.
    let downloadUrl:        String?
    /// Approximate download size in bytes (for UI display)
    let downloadSizeBytes:  Int64

    init(
        id: String,
        displayName: String,
        description: String? = nil,
        version: String? = nil,
        bundleResourceName: String? = nil,
        metadata: [String: Any] = [:],
        downloadUrl: String? = nil,
        downloadSizeBytes: Int64 = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.bundleResourceName = bundleResourceName
        self.metadata = metadata
        self.downloadUrl = downloadUrl
        self.downloadSizeBytes = downloadSizeBytes
    }

    /// Whether this model requires downloading before use
    var requiresDownload: Bool { downloadUrl != nil }

    /// Whether the model is available (bundled or already downloaded)
    var isAvailable: Bool {
        if downloadUrl == nil { return true } // Bundled
        guard let name = bundleResourceName else { return false }
        return ModelDownloadManager.shared.isDownloaded(resourceName: name)
    }

    func toDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "id":               id,
            "displayName":      displayName,
            "metadata":         metadata,
            "requiresDownload": requiresDownload,
            "isDownloaded":     isAvailable,
        ]
        if let desc = description   { d["description"] = desc }
        if let ver  = version       { d["version"] = ver }
        if downloadSizeBytes > 0    { d["downloadSizeBytes"] = downloadSizeBytes }
        if let url  = downloadUrl   { d["downloadUrl"] = url }
        return d
    }
}
