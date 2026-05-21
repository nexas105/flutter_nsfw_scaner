package com.example.nsfw_detect_ios

object ChannelConstants {
    const val METHOD_CHANNEL = "nsfw_detect_ios/methods"
    const val EVENT_CHANNEL = "nsfw_detect_ios/scan_events"

    object Method {
        const val REQUEST_PERMISSION = "requestPermission"
        const val CHECK_PERMISSION = "checkPermission"
        const val AVAILABLE_MODELS = "availableModels"
        const val PRELOAD_MODEL = "preloadModel"
        const val START_SCAN = "startScan"
        const val CANCEL_SCAN = "cancelScan"
        const val RESET_SCAN = "resetScan"
        const val SCAN_SINGLE_ASSET = "scanSingleAsset"
        const val SET_LOGGING = "setLogging"
        const val PICK_AND_SCAN = "pickAndScan"
        const val PICK_MEDIA = "pickMedia"
        const val SCAN_FILE = "scanFile"
        const val SCAN_BYTES = "scanBytes"
        const val CLEAR_SCAN_CACHE = "clearScanCache"

        // Model-management methods — must mirror iOS' ChannelConstants.swift.
        const val DOWNLOAD_MODEL = "downloadModel"
        const val DELETE_MODEL = "deleteModel"
        const val SET_MODEL_URL = "setModelUrl"

        // Live camera scan (v2.1.0 — Phase 03). Multiplexed onto the
        // existing scan_events EventChannel via the `type` discriminator.
        const val START_CAMERA_SCAN = "startCameraScan"
        const val STOP_CAMERA_SCAN = "stopCameraScan"

        /**
         * Reports the actual TFLite delegate the engine ended up loaded with
         * for a given model — "gpu", "nnapi" or "cpu". When the requested
         * delegate fails to instantiate the native side silently falls back
         * to CPU; this method lets Dart consumers detect that transparently.
         * The Dart agent has not wired this up yet (#20).
         */
        const val GET_DELEGATE_INFO = "getDelegateInfo"

        // v2.3.0 — cache lookup + prefetch + redaction (mirrors iOS
        // ChannelConstants.swift).
        const val CACHED_RESULT   = "cachedResult"
        const val PREFETCH_ASSETS = "prefetchAssets"
        const val REDACT_BYTES    = "redactBytes"
        const val REDACT_FILE     = "redactFile"
    }

    object EventKey {
        const val TYPE = "type"
        const val LOCAL_ID = "localId"
        const val MEDIA_TYPE = "mediaType"
        const val LABELS = "labels"
        const val CATEGORY = "category"
        const val CONFIDENCE = "confidence"
        const val SCANNED_COUNT = "scannedCount"
        const val TOTAL_COUNT = "totalCount"
        const val FRACTION = "fraction"
        const val IS_COMPLETE = "isComplete"
        const val STATUS = "status"
        const val ERROR_MESSAGE = "errorMessage"
        const val SCANNED_AT = "scannedAt"
        const val CURRENT_LOCAL_ID = "currentLocalId"
        const val CURRENT_MEDIA_TYPE = "currentMediaType"
        const val CREATION_DATE = "creationDate"
        const val DURATION_MS = "durationMs"
        const val WIDTH = "width"
        const val HEIGHT = "height"
        /** Detection-mode bounding boxes. List of `{label, confidence, box, aggregatedCategory}` maps. */
        const val DETECTIONS = "detections"

        // Live camera (Phase 03) — milliseconds-since-epoch capture timestamp
        // carried per cameraFrameResult event. Mirrors iOS' EventKey.frameTimestamp.
        const val FRAME_TIMESTAMP = "frameTimestamp"
    }

    /**
     * Discriminator values for the `type` key on the existing
     * `nsfw_detect_ios/scan_events` EventChannel. Camera events multiplex
     * onto the same channel; Phase-01 Dart contract filters by these.
     */
    object EventType {
        /** Per-frame classification / detection result from a live camera scan. */
        const val CAMERA_FRAME_RESULT = "cameraFrameResult"
        /** User denied (or system restricted) the runtime CAMERA permission. */
        const val CAMERA_PERMISSION_DENIED = "cameraPermissionDenied"
        /** Non-recoverable native camera-pipeline error. */
        const val CAMERA_ERROR = "cameraError"
    }
}
