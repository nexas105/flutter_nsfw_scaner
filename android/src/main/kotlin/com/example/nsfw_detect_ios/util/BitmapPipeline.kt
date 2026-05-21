package com.example.nsfw_detect_ios.util

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import com.example.nsfw_detect_ios.scanner.ScanConfiguration
import java.io.File

/**
 * Bitmap decode helpers shared by [com.example.nsfw_detect_ios.ScanSessionTask]
 * and [com.example.nsfw_detect_ios.ScanMethodHandler].
 *
 * Responsibilities (parity with iOS, where the OS does this for free via PHAsset):
 *  1. **Two-pass decode** with `BitmapFactory.inSampleSize` so we never
 *     allocate a full-res bitmap that's about to be resized to 224×224.
 *  2. **EXIF rotation** via [ExifInterface] — Android's BitmapFactory does
 *     NOT auto-rotate, so portrait-camera shots come out sideways and
 *     classifier confidence drops. We read orientation from a second
 *     InputStream (the decode stream is already consumed by then) and
 *     `Matrix.postRotate` the result.
 *  3. **Normalised-ROI crop** when [ScanConfiguration.roi] is set.
 *
 * Every intermediate bitmap is recycled before the function returns —
 * leaks were the symptom that motivated this helper (#1 / #2 / #8).
 */
object BitmapPipeline {

    private const val TAG = "NSFW-BitmapPipeline"

    /**
     * Two-pass downsampled decode + EXIF rotation + optional ROI crop.
     * Returns a single upright bitmap ready for the classifier, or `null`
     * if the URI couldn't be decoded.
     *
     * Caller owns the returned bitmap and MUST `recycle()` it after use.
     */
    fun decodeOriented(
        uri: Uri,
        contentResolver: ContentResolver,
        targetSize: Int,
        roi: ScanConfiguration.NormalizedRect? = null,
    ): Bitmap? {
        val decoded = decodeDownsampled(uri, contentResolver, targetSize) ?: return null
        val rotation = readExifRotation(uri, contentResolver)
        val rotated = rotateAndRecycle(decoded, rotation)
        return applyRoi(rotated, roi)
    }

    /**
     * File path variant — used by [com.example.nsfw_detect_ios.ScanMethodHandler.SCAN_FILE].
     * Reads EXIF directly from the file path (cheaper than re-opening a stream).
     */
    fun decodeOrientedFile(
        path: String,
        targetSize: Int,
        roi: ScanConfiguration.NormalizedRect? = null,
    ): Bitmap? {
        val decoded = decodeDownsampledFile(path, targetSize) ?: return null
        val rotation = try {
            orientationToDegrees(ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            ))
        } catch (_: Throwable) { 0 }
        val rotated = rotateAndRecycle(decoded, rotation)
        return applyRoi(rotated, roi)
    }

    /**
     * Bytes variant — used by [com.example.nsfw_detect_ios.ScanMethodHandler.SCAN_BYTES].
     */
    fun decodeOrientedBytes(
        bytes: ByteArray,
        targetSize: Int,
        roi: ScanConfiguration.NormalizedRect? = null,
    ): Bitmap? {
        val decoded = decodeDownsampledBytes(bytes, targetSize) ?: return null
        val rotation = try {
            orientationToDegrees(ExifInterface(bytes.inputStream()).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            ))
        } catch (_: Throwable) { 0 }
        val rotated = rotateAndRecycle(decoded, rotation)
        return applyRoi(rotated, roi)
    }

    // MARK: - EXIF

    private fun readExifRotation(uri: Uri, contentResolver: ContentResolver): Int {
        // ExifInterface(InputStream) consumes the stream; the caller's two-pass
        // decode already used its own streams so this is a fresh read.
        return try {
            contentResolver.openInputStream(uri)?.use { stream ->
                orientationToDegrees(
                    ExifInterface(stream).getAttributeInt(
                        ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
                    )
                )
            } ?: 0
        } catch (_: Throwable) {
            0
        }
    }

    private fun orientationToDegrees(orientation: Int): Int = when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> 90
        ExifInterface.ORIENTATION_ROTATE_180 -> 180
        ExifInterface.ORIENTATION_ROTATE_270 -> 270
        // Mirror cases are rare in modern phone cameras; treat as the
        // closest pure rotation to keep this helper simple.
        ExifInterface.ORIENTATION_TRANSVERSE -> 270
        ExifInterface.ORIENTATION_TRANSPOSE -> 90
        else -> 0
    }

    /** Rotate [src] by [degrees], recycling [src] if a new bitmap was allocated. */
    private fun rotateAndRecycle(src: Bitmap, degrees: Int): Bitmap {
        if (degrees == 0) return src
        return try {
            val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
            val rotated = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
            if (rotated !== src) {
                try { src.recycle() } catch (_: Throwable) {}
            }
            rotated
        } catch (t: Throwable) {
            Log.w(TAG, "rotate ${degrees}° failed: ${t.message}")
            src
        }
    }

    // MARK: - ROI

    private fun applyRoi(src: Bitmap, roi: ScanConfiguration.NormalizedRect?): Bitmap {
        if (roi == null || roi.isFull) return src
        if (!roi.isValid) {
            Log.w(TAG, "Invalid ROI $roi — using full bitmap")
            return src
        }
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src

        val x = (roi.x * w).toInt().coerceIn(0, w - 1)
        val y = (roi.y * h).toInt().coerceIn(0, h - 1)
        val cw = (roi.width  * w).toInt().coerceAtLeast(1).coerceAtMost(w - x)
        val ch = (roi.height * h).toInt().coerceAtLeast(1).coerceAtMost(h - y)
        if (cw <= 0 || ch <= 0) {
            Log.w(TAG, "ROI denormalised to zero area — using full bitmap")
            return src
        }
        return try {
            val cropped = Bitmap.createBitmap(src, x, y, cw, ch)
            if (cropped !== src) {
                try { src.recycle() } catch (_: Throwable) {}
            }
            cropped
        } catch (t: Throwable) {
            Log.w(TAG, "ROI crop $roi failed: ${t.message}")
            src
        }
    }

    // MARK: - Two-pass downsampled decode

    /**
     * Two-pass decode using BitmapFactory.inSampleSize so we never allocate a
     * full-resolution bitmap for an asset that ends up resized to 224×224.
     */
    fun decodeDownsampled(uri: Uri, contentResolver: ContentResolver, targetSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        } ?: return null

        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        val sample = computeSample(srcW, srcH, targetSize)
        val opts = BitmapFactory.Options().apply {
            inJustDecodeBounds = false
            inSampleSize = sample
        }
        return contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        }
    }

    private fun decodeDownsampledFile(path: String, targetSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) {
            return BitmapFactory.decodeFile(path)
        }
        val opts = BitmapFactory.Options().apply {
            inJustDecodeBounds = false
            inSampleSize = computeSample(srcW, srcH, targetSize)
        }
        return BitmapFactory.decodeFile(path, opts)
    }

    private fun decodeDownsampledBytes(bytes: ByteArray, targetSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) {
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
        val opts = BitmapFactory.Options().apply {
            inJustDecodeBounds = false
            inSampleSize = computeSample(srcW, srcH, targetSize)
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    private fun computeSample(srcW: Int, srcH: Int, targetSize: Int): Int {
        var sample = 1
        while (srcW / (sample * 2) >= targetSize && srcH / (sample * 2) >= targetSize) {
            sample *= 2
        }
        return sample
    }

    // MARK: - Safe recycle

    /** Best-effort recycle; never throws. */
    fun recycleQuietly(bitmap: Bitmap?) {
        if (bitmap == null) return
        try {
            if (!bitmap.isRecycled) bitmap.recycle()
        } catch (_: Throwable) {}
    }

    /** Unused but kept for symmetry with [decodeOrientedFile]; future callers may want file path. */
    @Suppress("unused")
    fun decodeOrientedFile(file: File, targetSize: Int, roi: ScanConfiguration.NormalizedRect? = null): Bitmap? =
        decodeOrientedFile(file.absolutePath, targetSize, roi)
}
