package com.example.nsfw_detect_ios.scanner

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import java.io.File

/**
 * Best-effort RAW-image decoder for the file-scan path.
 *
 * **Android RAW support is uneven.** The platform's [BitmapFactory] can
 * decode some DNG files (notably on API 31+) but does not handle the
 * vendor RAW formats (Canon CR2/CR3, Nikon NEF/NRW, Sony ARW, Fuji RAF,
 * Olympus ORF, Panasonic RW2, Adobe DNG variants from quirky tools, …).
 * There is no general-purpose RAW decoder in AOSP.
 *
 * Strategy:
 *  - For `.dng` files we attempt a direct [BitmapFactory] decode.
 *  - For all other RAW extensions we expose a separate
 *    [decodeEmbeddedPreview] path that pulls the JPEG thumbnail/preview
 *    embedded in the file's EXIF segment via [ExifInterface]. Virtually
 *    every modern camera writes a ≥1080p JPEG preview into the RAW
 *    container; that preview is plenty for NSFW classification.
 *
 * Defensive: catches [java.io.IOException], [OutOfMemoryError] (retries
 * with a larger `inSampleSize`) and [IllegalArgumentException].
 */
object RawImageDecoder {

    private const val TAG = "NSFW-RawDecoder"

    /**
     * Extensions that [decode] will attempt to handle directly.
     *
     * Only DNG is here — for any other RAW format the caller should fall
     * back to [decodeEmbeddedPreview]. See [rawExtensions] for the full
     * set of formats we'll attempt embedded-preview extraction on.
     */
    val supportedExtensions: Set<String> = setOf("dng")

    /**
     * Full set of RAW extensions for which we will try
     * [decodeEmbeddedPreview]. Adding a format here does not mean
     * [decode] will handle it.
     */
    val rawExtensions: Set<String> = setOf(
        "dng",
        "cr2", "cr3",      // Canon
        "nef", "nrw",      // Nikon
        "arw", "srf", "sr2",  // Sony
        "raf",             // Fuji
        "orf",             // Olympus
        "rw2",             // Panasonic
        "pef",             // Pentax
        "x3f",             // Sigma
        "3fr", "fff",      // Hasselblad
        "iiq",             // Phase One
        "k25", "kdc",      // Kodak
        "mef", "mos",      // Mamiya / Leaf
        "mrw",             // Minolta
        "rwl",             // Leica
    )

    /**
     * True when the caller should at least attempt a RAW path for this
     * file (either [decode] or [decodeEmbeddedPreview]).
     */
    fun canDecode(filePath: String): Boolean {
        val ext = File(filePath).extension.lowercase()
        return ext in rawExtensions
    }

    /**
     * Try to decode [filePath] as a regular bitmap. Returns null if the
     * extension is unsupported or the platform can't handle it.
     *
     * Currently only `.dng` files are attempted — and only Android 12+
     * (API 31) ships meaningful DNG support; older devices will likely
     * return null and the caller should fall back to
     * [decodeEmbeddedPreview]. Vendor RAW formats (CR2/NEF/ARW/…) always
     * return null here.
     */
    fun decode(filePath: String, targetWidth: Int, targetHeight: Int): Bitmap? {
        val ext = File(filePath).extension.lowercase()
        if (ext !in supportedExtensions) return null

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeFile(filePath, bounds)
        } catch (t: Throwable) {
            Log.w(TAG, "decode bounds failed for $filePath: ${t.message}")
            return null
        }
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        var sample = 1
        while (srcW / (sample * 2) >= targetWidth && srcH / (sample * 2) >= targetHeight) {
            sample *= 2
        }
        return decodeFileWithSample(filePath, sample)
    }

    /**
     * Pull the embedded JPEG preview from a RAW container via EXIF.
     *
     * Most modern cameras embed a full-resolution JPEG (≥1080p) inside
     * the RAW file as a thumbnail/preview; this method extracts that
     * JPEG and decodes it. Returns null if no thumbnail is present or
     * EXIF parsing fails.
     *
     * Works for any [rawExtensions] file (and indeed for JPEGs and TIFFs
     * with embedded thumbnails too, though the caller is expected to use
     * [decode] / [BitmapFactory] for those).
     */
    fun decodeEmbeddedPreview(filePath: String): Bitmap? {
        val exif: ExifInterface = try {
            ExifInterface(filePath)
        } catch (t: Throwable) {
            Log.w(TAG, "ExifInterface open failed for $filePath: ${t.message}")
            return null
        }
        if (!exif.hasThumbnail()) return null

        // ExifInterface caches the JPEG-encoded thumbnail; decoding it via
        // BitmapFactory rather than .thumbnailBitmap lets us downsample
        // huge embedded previews (some cameras ship 24MP+ thumbnails!).
        val bytes: ByteArray = try {
            exif.thumbnailBytes ?: return null
        } catch (t: Throwable) {
            Log.w(TAG, "thumbnailBytes failed for $filePath: ${t.message}")
            return null
        }

        return decodeBytesSafely(bytes)
    }

    // MARK: - Internal helpers

    private fun decodeFileWithSample(filePath: String, startSample: Int): Bitmap? {
        var sample = maxOf(1, startSample)
        while (sample <= 32) {
            try {
                val opts = BitmapFactory.Options().apply {
                    inJustDecodeBounds = false
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                val bmp = BitmapFactory.decodeFile(filePath, opts)
                if (bmp != null) return bmp
                // Some Android versions return null for unsupported DNGs
                // without throwing — bail rather than spin.
                return null
            } catch (oom: OutOfMemoryError) {
                Log.w(TAG, "decode OOM at sample=$sample — retrying smaller")
                sample *= 2
            } catch (iae: IllegalArgumentException) {
                Log.w(TAG, "BitmapFactory IAE: ${iae.message}")
                return null
            } catch (t: Throwable) {
                Log.w(TAG, "BitmapFactory decode failed: ${t.message}")
                return null
            }
        }
        return null
    }

    private fun decodeBytesSafely(bytes: ByteArray): Bitmap? {
        // Two-pass: read bounds, then choose a sensible sample size relative
        // to the canonical classifier input (224 long-edge minimum).
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        } catch (t: Throwable) {
            Log.w(TAG, "decode preview bounds failed: ${t.message}")
        }
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        var sample = 1
        if (srcW > 0 && srcH > 0) {
            val target = 224
            while (srcW / (sample * 2) >= target && srcH / (sample * 2) >= target) {
                sample *= 2
            }
        }

        while (sample <= 32) {
            try {
                val opts = BitmapFactory.Options().apply {
                    inJustDecodeBounds = false
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                if (bmp != null) return bmp
                return null
            } catch (oom: OutOfMemoryError) {
                Log.w(TAG, "preview decode OOM at sample=$sample — retrying smaller")
                sample *= 2
            } catch (iae: IllegalArgumentException) {
                Log.w(TAG, "BitmapFactory IAE on preview: ${iae.message}")
                return null
            } catch (t: Throwable) {
                Log.w(TAG, "BitmapFactory preview decode failed: ${t.message}")
                return null
            }
        }
        return null
    }
}
