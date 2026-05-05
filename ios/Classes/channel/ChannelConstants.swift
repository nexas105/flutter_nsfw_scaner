import Foundation

enum ChannelConstants {
    static let methodChannelName = "nsfw_detect_ios/methods"
    static let eventChannelName  = "nsfw_detect_ios/scan_events"

    enum Method {
        static let requestPermission  = "requestPermission"
        static let checkPermission    = "checkPermission"
        static let availableModels    = "availableModels"
        static let preloadModel       = "preloadModel"
        static let startScan          = "startScan"
        static let cancelScan         = "cancelScan"
        static let resetScan          = "resetScan"
        static let scanSingleAsset    = "scanSingleAsset"
        static let setLogging         = "setLogging"
        static let downloadModel      = "downloadModel"
        static let deleteModel        = "deleteModel"
        static let setModelUrl        = "setModelUrl"
        static let pickAndScan        = "pickAndScan"
        static let pickMedia          = "pickMedia"
        static let scanFile           = "scanFile"
        static let scanBytes          = "scanBytes"
        static let clearScanCache     = "clearScanCache"
    }

    enum EventKey {
        static let eventType        = "type"
        static let localId          = "localId"
        static let mediaType        = "mediaType"
        static let labels           = "labels"
        static let category         = "category"
        static let confidence       = "confidence"
        static let scannedCount     = "scannedCount"
        static let totalCount       = "totalCount"
        static let fraction         = "fraction"
        static let isComplete       = "isComplete"
        static let status           = "status"
        static let errorMessage     = "errorMessage"
        static let scannedAt        = "scannedAt"
        static let currentLocalId   = "currentLocalId"
        static let currentMediaType = "currentMediaType"
        static let creationDate     = "creationDate"
        static let durationMs       = "durationMs"
        static let width            = "width"
        static let height           = "height"
        static let detections       = "detections"
    }
}
