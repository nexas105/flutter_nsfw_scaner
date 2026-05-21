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
import java.security.MessageDigest

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
     *
     * @param expectedSha256 when non-null, the downloaded archive's SHA-256
     *   (lowercase hex) must match before extraction is attempted. Mismatch
     *   deletes the temp file and throws [ModelDownloadException].
     */
    suspend fun download(
        modelId: String,
        resourceName: String,
        url: String,
        expectedSha256: String? = null,
        onProgress: (Double) -> Unit = {},
    ): File {
        // Already on disk — short-circuit.
        localFile(resourceName)?.let {
            onProgress(1.0)
            return it
        }

        // Reject non-HTTPS up front. http:// would be silently downgrade-able
        // by anyone on the network path; file:// and friends bypass the
        // streamed-size enforcement. Integrators with a genuine need for
        // plaintext can stage models on disk manually.
        val scheme = runCatching { URL(url).protocol?.lowercase() }.getOrNull()
        if (scheme != "https") {
            throw ModelDownloadException("Refusing to download model over $scheme://. Use https://.")
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
                val file = performDownload(resourceName, url, expectedSha256, onProgress)
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
        expectedSha256: String?,
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
            // Content-Length pre-check (defense in depth — also enforced
            // during the streaming loop in case the header lies).
            if (total in 1..Long.MAX_VALUE && total > MAX_DOWNLOAD_BYTES) {
                throw ModelDownloadException(
                    "Model download too large: $total bytes (cap $MAX_DOWNLOAD_BYTES)"
                )
            }
            conn.inputStream.use { input ->
                tmpFile.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var written = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        written += n
                        if (written > MAX_DOWNLOAD_BYTES) {
                            // Stop writing, surface a clear error. A lying
                            // server can advertise a tiny Content-Length and
                            // stream gigabytes — this catches that.
                            throw ModelDownloadException(
                                "Model download exceeded $MAX_DOWNLOAD_BYTES-byte cap (received $written bytes)"
                            )
                        }
                        output.write(buf, 0, n)
                        if (total > 0) {
                            onProgress((written.toDouble() / total.toDouble()).coerceIn(0.0, 1.0))
                        }
                    }
                }
            }
        } finally {
            conn.disconnect()
        }

        // Optional pinned-hash verification before extraction. We hash even
        // when the download came from a "trusted" URL — pinning is cheap
        // (a couple hundred ms on a 150 MB file) and protects against
        // mid-stream tampering or a release tag pointing at the wrong
        // artifact.
        if (!expectedSha256.isNullOrBlank()) {
            val pin = expectedSha256.lowercase()
            val actual = sha256Hex(tmpFile)
            if (actual != pin) {
                tmpFile.delete()
                throw ModelDownloadException(
                    "Model archive SHA-256 mismatch — expected $pin, got $actual"
                )
            }
        }

        // Detect the archive shape via magic bytes. PK\x03\x04 → ZIP, must
        // succeed at extraction. Otherwise: only accept the payload as a raw
        // .tflite if it carries the FlatBuffer file-identifier — refusing
        // arbitrary bytes (HTML error pages, partial downloads, etc.) that
        // the old silent fallback would have happily renamed to .tflite.
        val extractDir = File(modelsDirectory, "_extract_$resourceName")
        if (extractDir.exists()) extractDir.deleteRecursively()
        val finalPath: File = try {
            when {
                isZipArchive(tmpFile) -> {
                    ZipExtractor.extract(
                        tmpFile,
                        extractDir,
                        maxTotalBytes = MAX_EXTRACTED_BYTES,
                        maxEntries = MAX_ARCHIVE_ENTRIES,
                        maxCompressionRatio = MAX_COMPRESSION_RATIO,
                    )
                    placeExtractedArtifact(extractDir, resourceName)
                }
                isTFLiteFlatBuffer(tmpFile) -> {
                    val flat = File(modelsDirectory, "$resourceName.tflite")
                    if (flat.exists()) flat.delete()
                    tmpFile.copyTo(flat, overwrite = true)
                    flat
                }
                else -> throw ModelDownloadException(
                    "Downloaded artifact is neither a ZIP archive nor a TFLite flatbuffer — refusing to install"
                )
            }
        } finally {
            if (extractDir.exists()) extractDir.deleteRecursively()
            if (tmpFile.exists()) tmpFile.delete()
        }

        onProgress(1.0)
        Log.i(TAG, "Model ready: $resourceName at ${finalPath.absolutePath}")
        finalPath
    }

    /** PK\x03\x04 local-file-header signature. */
    private fun isZipArchive(file: File): Boolean {
        if (file.length() < 4) return false
        return file.inputStream().use { input ->
            val head = ByteArray(4)
            val n = input.read(head)
            n == 4 &&
                head[0] == 0x50.toByte() && head[1] == 0x4B.toByte() &&
                head[2] == 0x03.toByte() && head[3] == 0x04.toByte()
        }
    }

    /** TFLite FlatBuffer carries `TFL3` at offset 4. */
    private fun isTFLiteFlatBuffer(file: File): Boolean {
        if (file.length() < 8) return false
        return file.inputStream().use { input ->
            val head = ByteArray(8)
            val n = input.read(head)
            n == 8 &&
                head[4] == 'T'.code.toByte() && head[5] == 'F'.code.toByte() &&
                head[6] == 'L'.code.toByte() && head[7] == '3'.code.toByte()
        }
    }

    /** Stream-SHA-256 the file in 64 KB chunks; returns lowercase hex. */
    private fun sha256Hex(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
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

        // Hard caps applied to every download. Tuned wide enough for the
        // largest bundled descriptor plus headroom, tight enough that a
        // zip bomb or 4 GB blob can't run away with the user's storage.
        const val MAX_DOWNLOAD_BYTES:    Long   = 500_000_000L
        const val MAX_EXTRACTED_BYTES:   Long   = 600_000_000L
        const val MAX_ARCHIVE_ENTRIES:   Int    = 4096
        const val MAX_COMPRESSION_RATIO: Double = 200.0

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
