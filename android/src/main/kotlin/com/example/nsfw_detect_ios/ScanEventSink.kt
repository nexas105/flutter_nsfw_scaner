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
        height: Int? = null
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
}
