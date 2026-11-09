import Foundation

enum ChannelConstants {
    static let methodChannelName = "nsfw_detect_ios/methods"
    static let eventChannelName  = "nsfw_detect_ios/scan_events"

    enum Method {
        static let requestPermission        = "requestPermission"
        static let checkPermission          = "checkPermission"
        static let checkCameraPermission    = "checkCameraPermission"
        static let requestCameraPermission  = "requestCameraPermission"
        static let checkPlatformSetup       = "checkPlatformSetup"
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
        static let startCameraScan    = "startCameraScan"
        static let stopCameraScan     = "stopCameraScan"
        /// iOS-only diagnostics: returns the `MLComputeUnits` the supplied
        /// modelId is currently loaded with (or `.all` if not yet loaded).
        /// See Task #20 / CoreMLEngine.loadedComputeUnits.
        static let getComputeUnits    = "getComputeUnits"

        // v2.3.0 — cache lookup + prefetch + redaction (mirrors Android
        // ChannelConstants.Method).
        static let cachedResult       = "cachedResult"
        static let prefetchAssets     = "prefetchAssets"
        static let redactBytes        = "redactBytes"
        static let redactFile         = "redactFile"
        static let loadThumbnail      = "loadThumbnail"
        static let exportAsset        = "exportAsset"
        static let skipCurrentAsset   = "skipCurrentAsset"
        static let registerModel      = "registerModel"
        static let scheduleBackgroundSweep = "scheduleBackgroundSweep"
        static let cancelBackgroundSweep   = "cancelBackgroundSweep"

        // v2.7.0 — native asset management (favorite / hide / delete / albums).
        // All operate on the *original* PHAsset via the photo library; require
        // `.readWrite` authorization (already requested by requestPermission).
        static let setAssetFavorite     = "setAssetFavorite"
        static let setAssetHidden       = "setAssetHidden"
        static let deleteAssets         = "deleteAssets"
        static let listAlbums           = "listAlbums"
        static let createAlbum          = "createAlbum"
        static let addAssetsToAlbum     = "addAssetsToAlbum"
        static let removeAssetsFromAlbum = "removeAssetsFromAlbum"
        static let moveAssetsToAlbum    = "moveAssetsToAlbum"

        // v2.7.0 — enumerate library asset identifiers. Lets Dart drive a
        // batch *ensemble* scan (run each asset through scanAssetEnsemble) —
        // the native session path is single-model only.
        static let listAssetIdentifiers = "listAssetIdentifiers"
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
        // Camera (Phase 02). Match the schema Phase 01's CameraFrameResult
        // / CameraScanSession parses on the Dart side.
        static let frameTimestamp   = "frameTimestamp"
        static let frameId          = "frameId"
        static let message          = "message"
    }

    /// Discriminator values for the `type` field on the existing
    /// `nsfw_detect_ios/scan_events` EventChannel. Camera events live on the
    /// same channel as photo-library events (per Phase 01 CAM-06).
    enum EventType {
        static let cameraFrameResult      = "cameraFrameResult"
        static let cameraPermissionDenied = "cameraPermissionDenied"
        static let cameraError            = "cameraError"
    }
}
