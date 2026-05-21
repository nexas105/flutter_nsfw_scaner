package com.example.nsfw_detect_ios.background

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.example.nsfw_detect_ios.ScanEventSink
import com.example.nsfw_detect_ios.ScanSessionTask
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import org.json.JSONObject

/**
 * Periodic background scan, scheduled via `WorkManager.enqueueUniquePeriodicWork`.
 *
 * Runs without a Flutter engine — emits its per-asset results to a no-op
 * [ScanEventSink], relies on the on-device `ScanCache` SQLite layer to
 * persist labels. The host app reads them back on next launch via
 * `NsfwDetector.cachedResult(...)` / `NsfwDetector.cacheUpdates`.
 *
 * Wakes up with a serialized [ScanConfiguration] in [WorkerParameters.inputData];
 * `resumeFromCheckpoint` is forced to true so the worker cooperates with any
 * foreground session the user later runs.
 *
 * Cancellation: `WorkManager.cancelUniqueWork(...)` cancels [doWork]'s
 * coroutine, which propagates into [session.awaitCompletion] and the
 * underlying [scanJob].
 */
class NsfwSweepWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val configJson = inputData.getString(KEY_SCAN_CONFIG_JSON)
        if (configJson.isNullOrBlank()) {
            Log.w(TAG, "doWork: missing scanConfig — skipping run")
            return Result.failure()
        }
        return try {
            val config = parseScanConfig(configJson)
            // No Flutter engine in this process — sink.emit() is a no-op
            // because no EventChannel listener is attached. Results land in
            // ScanCache regardless and are visible to the host app on its
            // next foreground launch via NsfwDetector.cachedResult /
            // cacheUpdates.
            val sink = ScanEventSink()
            val session = ScanSessionTask(applicationContext, config, sink)
            session.start()
            session.awaitCompletion()
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "doWork failed: ${e.message}", e)
            Result.retry()
        }
    }

    private fun parseScanConfig(json: String): ScanConfiguration {
        val obj = JSONObject(json)
        val map = HashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            map[k] = obj.opt(k)
        }
        // Force resume — the whole point of a background sweep is to chip
        // away at the library across runs.
        map["resumeFromCheckpoint"] = true
        return ScanConfiguration.from(map)
    }

    companion object {
        const val TAG = "NsfwSweepWorker"
        const val WORK_NAME = "nsfw_detect.background_sweep"
        const val KEY_SCAN_CONFIG_JSON = "scanConfigJson"
    }
}
