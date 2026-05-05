package com.example.nsfw_detect_ios.ml

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads on-demand .tflite model archives, extracts them, and stores the
 * result under `<filesDir>/nsfw_models/`. Active downloads for the same model
 * id are deduplicated so concurrent callers share a single HTTP fetch.
 *
 * Pendant to `ios/Classes/ml/ModelDownloadManager.swift`. Uses vanilla
 * `HttpURLConnection` + `ZipInputStream` — no extra Gradle dependency.
 */
class ModelDownloadManager private constructor(appContext: Context) {

    private val appContext: Context = appContext.applicationContext

    /** Persistent directory for downloaded models. */
    val modelsDirectory: File = File(this.appContext.filesDir, "nsfw_models").apply {
        if (!exists()) mkdirs()
    }

    private val lock = Any()
    private val activeDownloads = mutableMapOf<String, CompletableDeferred<File>>()
    private val ioScope = CoroutineScope(Dispatchers.IO)

    /** True if a downloaded artifact for [resourceName] exists on disk. */
    fun isDownloaded(resourceName: String): Boolean = localFile(resourceName) != null

    /**
     * Returns the on-disk path of a previously-downloaded model, or null.
     *
     * Looks for `<resourceName>.tflite` first; falls back to `<resourceName>/`
     * (directory layout for multi-file archives, mirrors iOS' .mlmodelc folder).
     */
    fun localFile(resourceName: String): File? {
        val flatFile = File(modelsDirectory, "$resourceName.tflite")
        if (flatFile.exists() && flatFile.isFile) return flatFile
        val dir = File(modelsDirectory, resourceName)
        if (dir.exists() && dir.isDirectory) return dir
        return null
    }

    /**
     * Download and extract the archive at [url]. Returns the resulting on-disk path.
     *
     * Concurrent calls for the same [modelId] reuse a single in-flight job.
     * The [onProgress] callback is invoked from a background thread with values
     * in `[0.0, 1.0]`.
     */
    suspend fun download(
        modelId: String,
        resourceName: String,
        url: String,
        onProgress: (Double) -> Unit = {},
    ): File {
        // Already on disk — short-circuit.
        localFile(resourceName)?.let {
            onProgress(1.0)
            return it
        }

        val deferred: CompletableDeferred<File>
        var alreadyRunning = false

        synchronized(lock) {
            val existing = activeDownloads[modelId]
            if (existing != null) {
                deferred = existing
                alreadyRunning = true
            } else {
                deferred = CompletableDeferred()
                activeDownloads[modelId] = deferred
            }
        }

        if (alreadyRunning) return deferred.await()

        ioScope.launch {
            try {
                val file = performDownload(resourceName, url, onProgress)
                deferred.complete(file)
            } catch (t: Throwable) {
                deferred.completeExceptionally(t)
            } finally {
                synchronized(lock) { activeDownloads.remove(modelId) }
            }
        }

        return deferred.await()
    }

    /** Delete the on-disk artifact for [resourceName] (if any). */
    fun delete(resourceName: String) {
        val flat = File(modelsDirectory, "$resourceName.tflite")
        if (flat.exists()) flat.delete()
        val dir = File(modelsDirectory, resourceName)
        if (dir.exists()) dir.deleteRecursively()
    }

    /** Total disk usage of the models directory in bytes. */
    fun downloadedSizeBytes(): Long {
        if (!modelsDirectory.exists()) return 0
        var total = 0L
        modelsDirectory.walkTopDown().forEach { f ->
            if (f.isFile) total += f.length()
        }
        return total
    }

    // MARK: - Private

    private suspend fun performDownload(
        resourceName: String,
        url: String,
        onProgress: (Double) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        Log.i(TAG, "Downloading $resourceName from $url")

        val tmpFile = File(appContext.cacheDir, "nsfw_dl_${resourceName}_${System.currentTimeMillis()}.bin")
        if (tmpFile.exists()) tmpFile.delete()

        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 60_000
            requestMethod = "GET"
            instanceFollowRedirects = true
        }
        try {
            conn.connect()
            val code = conn.responseCode
            if (code !in 200..299) {
                throw ModelDownloadException("HTTP $code while downloading $resourceName")
            }
            val total = conn.contentLengthLong
            conn.inputStream.use { input ->
                tmpFile.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var written = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                        written += n
                        if (total > 0) {
                            onProgress((written.toDouble() / total.toDouble()).coerceIn(0.0, 1.0))
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }

        // Try ZIP extraction. If that fails, treat the payload as a raw .tflite.
        val extractDir = File(modelsDirectory, "_extract_$resourceName")
        if (extractDir.exists()) extractDir.deleteRecursively()

        val finalPath: File = try {
            ZipExtractor.extract(tmpFile, extractDir)
            placeExtractedArtifact(extractDir, resourceName)
        } catch (e: Exception) {
            Log.w(TAG, "ZIP extraction failed (${e.message}), falling back to raw .tflite copy")
            val flat = File(modelsDirectory, "$resourceName.tflite")
            if (flat.exists()) flat.delete()
            tmpFile.copyTo(flat, overwrite = true)
            flat
        } finally {
            if (extractDir.exists()) extractDir.deleteRecursively()
            if (tmpFile.exists()) tmpFile.delete()
        }

        onProgress(1.0)
        Log.i(TAG, "Model ready: $resourceName at ${finalPath.absolutePath}")
        finalPath
    }

    /**
     * Move extracted content into the canonical location.
     *
     * Strategy:
     *  - if exactly one .tflite file is found anywhere in the extracted tree,
     *    move it to `<modelsDir>/<resourceName>.tflite`.
     *  - otherwise move the whole extracted dir to `<modelsDir>/<resourceName>/`.
     */
    private fun placeExtractedArtifact(extractDir: File, resourceName: String): File {
        val tflite = extractDir.walkTopDown().firstOrNull { it.isFile && it.name.endsWith(".tflite") }
        if (tflite != null && tflite.isFile) {
            val dest = File(modelsDirectory, "$resourceName.tflite")
            if (dest.exists()) dest.delete()
            // Try a fast rename, fall back to copy if cross-device.
            if (!tflite.renameTo(dest)) {
                tflite.copyTo(dest, overwrite = true)
            }
            return dest
        }
        // Directory layout: keep the whole thing.
        val destDir = File(modelsDirectory, resourceName)
        if (destDir.exists()) destDir.deleteRecursively()
        if (!extractDir.renameTo(destDir)) {
            extractDir.copyRecursively(destDir, overwrite = true)
        }
        return destDir
    }

    companion object {
        private const val TAG = "NSFW-DL"

        @Volatile
        private var INSTANCE: ModelDownloadManager? = null

        fun getInstance(context: Context): ModelDownloadManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: ModelDownloadManager(context).also { INSTANCE = it }
            }
        }
    }
}

class ModelDownloadException(message: String) : IOException(message)
