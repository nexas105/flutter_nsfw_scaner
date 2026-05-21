package com.example.nsfw_detect_ios.cache

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * Resumable-scan checkpoint store. Persists `{sessionId, scanConfigHash,
 * lastProcessedAssetId, processedCount, totalCount}` to a small JSON file
 * under `<cacheDir>/nsfw_detect/checkpoints/<configHash>.json`.
 *
 * Mirrors the iOS `CheckpointWriter` in `ScanSessionTask.swift:798-834`, but
 * keyed by `configHash` so two scans with different configs can resume
 * independently and don't trample each other.
 *
 * Throttling: [record] writes to disk at most every [everyN] items or every
 * [everyMs] milliseconds — whichever comes first. [flush] forces a write
 * (call at session boundaries). [clear] removes the file once a scan
 * completes normally.
 *
 * Thread-safety: every public method is guarded by [lock]; safe from any
 * coroutine dispatcher.
 */
class ScanCheckpoint(
    private val context: Context,
    /**
     * Stable hash of `(modelId, mode, confidenceThreshold, includeVideos,
     * forceRescan, assetIdentifiers)` — anything that changes the set of
     * assets we'd scan. Two configs with the same hash share a file; two
     * with different hashes coexist.
     */
    val configHash: String,
    private val everyN: Int = 25,
    private val everyMs: Long = 5_000L,
) {

    /** Snapshot returned by [load]. */
    data class State(
        val sessionId: String,
        val scanConfigHash: String,
        val lastProcessedAssetId: String?,
        val processedAssetIds: Set<String>,
        val processedCount: Int,
        val totalCount: Int,
        val updatedAtMs: Long,
    )

    private val lock = Any()
    private val file: File = run {
        val dir = File(context.cacheDir, "nsfw_detect/checkpoints")
        if (!dir.exists()) dir.mkdirs()
        File(dir, "$configHash.json")
    }

    private var sessionId: String = generateSessionId()
    private var lastProcessedAssetId: String? = null
    private val processedAssetIds = LinkedHashSet<String>()
    private var processedCount: Int = 0
    private var totalCount: Int = 0
    private var counter: Int = 0
    private var lastWriteMs: Long = 0L
    // Tracks whether in-memory state has changed since the last successful
    // flush. Lets flush() short-circuit a no-op rewrite — important because
    // record() may trigger flush() on a time-throttle even when no new asset
    // was processed in the window, and large libraries make each serialize()
    // pass non-trivial (whole processedAssetIds set rebuilt into a JSONArray).
    private var dirty: Boolean = false

    /**
     * Load any previously-written checkpoint for this [configHash]. Returns
     * null when no file exists or the JSON is unreadable. Side effect: the
     * loaded state becomes the in-memory baseline so subsequent [record]
     * calls extend it instead of starting fresh.
     */
    fun load(): State? {
        synchronized(lock) {
            if (!file.exists()) return null
            return try {
                val obj = JSONObject(file.readText(Charsets.UTF_8))
                val sid = obj.optString("sessionId").ifEmpty { generateSessionId() }
                val cfg = obj.optString("scanConfigHash").ifEmpty { configHash }
                val last = obj.optString("lastProcessedAssetId").takeIf { it.isNotEmpty() }
                val processedArr = obj.optJSONArray("processedAssetIds")
                val processed = LinkedHashSet<String>()
                if (processedArr != null) {
                    for (i in 0 until processedArr.length()) {
                        processedArr.optString(i, "").takeIf { it.isNotEmpty() }?.let {
                            processed.add(it)
                        }
                    }
                }
                val pc = obj.optInt("processedCount", processed.size)
                val tc = obj.optInt("totalCount", 0)
                val updated = obj.optLong("updatedAtMs", 0L)

                sessionId = sid
                lastProcessedAssetId = last
                processedAssetIds.clear()
                processedAssetIds.addAll(processed)
                processedCount = pc
                totalCount = tc

                State(sid, cfg, last, processed, pc, tc, updated)
            } catch (e: Exception) {
                Log.w(TAG, "load failed for $configHash: ${e.message}")
                null
            }
        }
    }

    /**
     * Initialise / re-initialise the in-memory state for a fresh scan. Does
     * NOT write to disk — call [flush] (or trigger an automatic write via
     * [record]) to persist.
     */
    fun beginSession(total: Int) {
        synchronized(lock) {
            sessionId = generateSessionId()
            lastProcessedAssetId = null
            processedAssetIds.clear()
            processedCount = 0
            totalCount = total
            counter = 0
            lastWriteMs = 0L
        }
    }

    /**
     * Note that [assetId] just finished processing. Writes to disk lazily —
     * every [everyN] records or [everyMs] milliseconds since the last write,
     * whichever fires first. Pass `total` only if it changed mid-scan.
     */
    fun record(assetId: String, total: Int = totalCount) {
        val shouldWrite: Boolean
        synchronized(lock) {
            if (processedAssetIds.add(assetId)) {
                processedCount += 1
                dirty = true
            }
            lastProcessedAssetId = assetId
            if (total > 0 && total != totalCount) {
                totalCount = total
                dirty = true
            }
            counter += 1
            val now = System.currentTimeMillis()
            shouldWrite = dirty && (counter >= everyN || (now - lastWriteMs) >= everyMs)
            if (shouldWrite) {
                lastWriteMs = now
                counter = 0
            }
        }
        if (shouldWrite) flush()
    }

    /** Force a disk write of the current in-memory state. */
    fun flush() {
        val payload: String?
        synchronized(lock) {
            if (!dirty) return
            payload = serialize()
            lastWriteMs = System.currentTimeMillis()
            counter = 0
            dirty = false
        }
        try {
            file.writeText(payload!!, Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w(TAG, "flush failed for $configHash: ${e.message}")
            synchronized(lock) { dirty = true } // retry next time
        }
    }

    /** Remove the checkpoint file (called on normal completion). */
    fun clear() {
        synchronized(lock) {
            lastProcessedAssetId = null
            processedAssetIds.clear()
            processedCount = 0
            totalCount = 0
            counter = 0
            lastWriteMs = 0L
        }
        try {
            if (file.exists()) file.delete()
        } catch (_: Throwable) {}
    }

    private fun serialize(): String {
        val obj = JSONObject()
        obj.put("sessionId", sessionId)
        obj.put("scanConfigHash", configHash)
        obj.put("lastProcessedAssetId", lastProcessedAssetId ?: "")
        obj.put("processedCount", processedCount)
        obj.put("totalCount", totalCount)
        obj.put("updatedAtMs", System.currentTimeMillis())
        val arr = org.json.JSONArray()
        for (id in processedAssetIds) arr.put(id)
        obj.put("processedAssetIds", arr)
        return obj.toString()
    }

    private fun generateSessionId(): String =
        "${System.currentTimeMillis()}-${(Math.random() * 1_000_000).toLong()}"

    companion object {
        private const val TAG = "NSFW-Checkpoint"

        /**
         * Stable hash of the config knobs that change the set of assets a
         * scan would process. Two configs hashing the same value share a
         * checkpoint file; two with different hashes coexist in their own
         * files.
         */
        fun computeConfigHash(
            modelId: String,
            mode: String,
            confidenceThreshold: Double,
            includeVideos: Boolean,
            forceRescan: Boolean,
            assetIdentifiers: List<String>?,
            skipAssetIds: List<String>?,
            includeOnlyAssetIds: List<String>?,
        ): String {
            val parts = buildString {
                append("m=").append(modelId).append('|')
                append("mode=").append(mode).append('|')
                append("ct=").append("%.4f".format(confidenceThreshold)).append('|')
                append("vid=").append(includeVideos).append('|')
                append("force=").append(forceRescan).append('|')
                append("ids=").append(assetIdentifiers?.sorted()?.joinToString(",") ?: "*").append('|')
                append("skip=").append(skipAssetIds?.sorted()?.joinToString(",") ?: "").append('|')
                append("only=").append(includeOnlyAssetIds?.sorted()?.joinToString(",") ?: "")
            }
            val md = MessageDigest.getInstance("SHA-256")
            val digest = md.digest(parts.toByteArray(Charsets.UTF_8))
            // 16 hex chars (64 bits) — plenty of distinctness, keeps filenames sane.
            return digest.take(8).joinToString("") { "%02x".format(it) }
        }
    }
}
