package com.example.nsfw_detect_ios

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridges native scan events to Flutter's EventChannel.
 * Thread-safe: emit() can be called from any thread.
 * All EventSink.success() calls are dispatched on the main thread.
 */
class ScanEventSink : EventChannel.StreamHandler {

    @Volatile
    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // MARK: - EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // MARK: - Emit helpers

    fun emit(event: Map<String, Any?>) {
        mainHandler.post { sink?.success(event) }
    }

    fun emitResult(
        localId: String,
        mediaType: String,
        status: String,
        scannedAt: Long,
        labels: List<Map<String, Any>>,
        errorMessage: String? = null,
        creationDate: Long? = null,
        durationMs: Int? = null,
        width: Int? = null,
        height: Int? = null,
        detections: List<Map<String, Any>>? = null,
    ) {
        val map = mutableMapOf<String, Any?>(
            ChannelConstants.EventKey.TYPE to "result",
            ChannelConstants.EventKey.LOCAL_ID to localId,
            ChannelConstants.EventKey.MEDIA_TYPE to mediaType,
            ChannelConstants.EventKey.STATUS to status,
            ChannelConstants.EventKey.SCANNED_AT to scannedAt,
            ChannelConstants.EventKey.LABELS to labels
        )
        if (errorMessage != null) map[ChannelConstants.EventKey.ERROR_MESSAGE] = errorMessage
        if (creationDate != null) map[ChannelConstants.EventKey.CREATION_DATE] = creationDate
        if (durationMs != null) map[ChannelConstants.EventKey.DURATION_MS] = durationMs
        if (width != null) map[ChannelConstants.EventKey.WIDTH] = width
        if (height != null) map[ChannelConstants.EventKey.HEIGHT] = height
        if (detections != null && detections.isNotEmpty()) {
            map[ChannelConstants.EventKey.DETECTIONS] = detections
        }
        emit(map)
    }

    fun emitProgress(
        scannedCount: Int,
        totalCount: Int,
        isComplete: Boolean,
        currentLocalId: String? = null,
        currentMediaType: String? = null
    ) {
        val fraction = if (totalCount > 0) scannedCount.toDouble() / totalCount else 0.0
        val map = mutableMapOf<String, Any?>(
            ChannelConstants.EventKey.TYPE to "progress",
            ChannelConstants.EventKey.SCANNED_COUNT to scannedCount,
            ChannelConstants.EventKey.TOTAL_COUNT to totalCount,
            ChannelConstants.EventKey.FRACTION to fraction,
            ChannelConstants.EventKey.IS_COMPLETE to isComplete
        )
        if (currentLocalId != null) map[ChannelConstants.EventKey.CURRENT_LOCAL_ID] = currentLocalId
        if (currentMediaType != null) map[ChannelConstants.EventKey.CURRENT_MEDIA_TYPE] = currentMediaType
        emit(map)
    }

    fun emitError(code: String, message: String) {
        emit(mapOf(
            ChannelConstants.EventKey.TYPE to "error",
            "code" to code,
            "message" to message
        ))
    }

    // MARK: - Live camera scan helpers (Phase 03)

    /**
     * Emit a single per-frame camera classification / detection result.
     *
     * Schema mirrors CAM-06 / iOS:
     *  - `type`            = "cameraFrameResult"
     *  - `frameTimestamp`  = capture time in millis (epoch / monotonic ms)
     *  - `labels`          = list of `{category, confidence}` maps
     *  - `detections`      = optional list of `BodyPartDetection.toMap()` entries
     *  - `scannedAt`       = wall-clock millis when the result was produced
     */
    fun emitCameraFrameResult(
        frameTimestampMs: Long,
        labels: List<Map<String, Any>>,
        detections: List<Map<String, Any>>?,
    ) {
        val map = mutableMapOf<String, Any?>(
            ChannelConstants.EventKey.TYPE to ChannelConstants.EventType.CAMERA_FRAME_RESULT,
            ChannelConstants.EventKey.FRAME_TIMESTAMP to frameTimestampMs,
            ChannelConstants.EventKey.LABELS to labels,
            ChannelConstants.EventKey.SCANNED_AT to System.currentTimeMillis(),
        )
        if (!detections.isNullOrEmpty()) {
            map[ChannelConstants.EventKey.DETECTIONS] = detections
        }
        emit(map)
    }

    /**
     * Emit a one-shot permission-denied event. The Dart-side
     * [CameraScanSession] surfaces this as a [CameraPermissionDeniedException]
     * on its results stream and resolves `done`.
     */
    fun emitCameraPermissionDenied(message: String? = null) {
        emit(
            mapOf(
                ChannelConstants.EventKey.TYPE to
                    ChannelConstants.EventType.CAMERA_PERMISSION_DENIED,
                "message" to (message ?: "Camera permission denied"),
            )
        )
    }

    /**
     * Emit a non-recoverable camera-pipeline error. Surfaces as a
     * [CameraErrorException] on the Dart-side stream.
     */
    fun emitCameraError(message: String) {
        emit(
            mapOf(
                ChannelConstants.EventKey.TYPE to ChannelConstants.EventType.CAMERA_ERROR,
                "message" to message,
            )
        )
    }
}
