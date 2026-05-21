package com.example.nsfw_detect_ios.scanner

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Movie
import android.os.Build
import android.util.Log
import com.example.nsfw_detect_ios.util.BitmapPipeline
import java.io.File
import java.io.FileInputStream

/**
 * Frame sampler for animated images (GIF / animated WebP / animated HEIF).
 *
 * Android does not provide a uniform API for extracting individual frames
 * from animated images, so this helper combines two compromise paths:
 *  - **GIF (any API):** uses the legacy [Movie] decoder. Deprecated but the
 *    only built-in API that exposes `setTime()` / `draw(canvas)` and works
 *    back to API 1.
 *  - **Animated WebP / HEIF (API 28+):** decodes via [ImageDecoder] into a
 *    single [Bitmap]. The platform doesn't expose individual frames from
 *    `ImageDecoder.decodeBitmap` so we ship a *single-frame* fallback for
 *    these formats. Real frame extraction would require shipping a third
 *    party WebP demuxer; deferred (see TODO below).
 *
 * Frames are returned downsampled toward [targetWidth]×[targetHeight] and
 * with the optional [ScanConfiguration.NormalizedRect] crop applied. The
 * caller owns each returned bitmap and MUST recycle them.
 *
 * Defensive: catches [IOException], [OutOfMemoryError] and
 * [IllegalArgumentException]. On OOM, downsamples and retries.
 */
object AnimatedImageSampler {

    private const val TAG = "NSFW-AnimSampler"

    /** Magic bytes for "GIF8" — both GIF87a and GIF89a start with this. */
    private val GIF_MAGIC = byteArrayOf(0x47, 0x49, 0x46, 0x38)
    /** "RIFF" header — WebP files. We then need to check for "WEBPVP8X" / "ANIM". */
    private val RIFF_MAGIC = byteArrayOf(0x52, 0x49, 0x46, 0x46)

    /**
     * Detect whether [filePath] points to an animated image by sniffing
     * magic bytes (extension fallback). Returns false on any read error.
     */
    fun isAnimated(filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return false
        return try {
            val header = ByteArray(32)
            FileInputStream(file).use { it.read(header) }
            // GIFs: every GIF is potentially animated; we treat them as animated
            // since Movie.duration() will tell us at decode time.
            if (header.startsWithBytes(GIF_MAGIC)) return true
            // WebP: must contain RIFF...WEBP...ANIM chunk for animation.
            if (header.startsWithBytes(RIFF_MAGIC)) {
                // Bytes 8..11 should be "WEBP".
                if (header.size >= 16 &&
                    header[8] == 0x57.toByte() && header[9] == 0x45.toByte() &&
                    header[10] == 0x42.toByte() && header[11] == 0x50.toByte()
                ) {
                    // Look for "ANIM" within the first 64 bytes (best-effort).
                    val bigger = ByteArray(64)
                    FileInputStream(file).use { it.read(bigger) }
                    val s = String(bigger, Charsets.ISO_8859_1)
                    if (s.contains("ANIM") || s.contains("ANMF")) return true
                }
            }
            // Animated HEIF / HEIC sequences are rare on Android; treat by
            // extension only.
            val ext = file.extension.lowercase()
            ext == "gif"  // any GIF is potentially animated
        } catch (t: Throwable) {
            Log.w(TAG, "isAnimated($filePath) failed: ${t.message}")
            false
        }
    }

    /**
     * Sample up to [maxFrames] evenly-spaced frames from an animated image.
     *
     * On API < 28 (and for non-GIF animated formats on any API), this
     * returns a single-element list with the first frame — multi-frame
     * extraction for animated WebP / HEIF requires platform support that
     * Android doesn't expose without third-party libraries.
     *
     * @param filePath absolute path to a GIF / WebP / HEIF file
     * @param maxFrames upper bound on frames returned (>=1)
     * @param targetWidth target frame width (decoded frames will be at
     *                    most this size on the long edge)
     * @param targetHeight target frame height
     * @param roi optional normalised crop applied to every frame
     * @return list of bitmaps (at least 1 on success, empty on failure).
     *         Caller owns each bitmap and must recycle.
     */
    fun sampleFrames(
        filePath: String,
        maxFrames: Int = 8,
        targetWidth: Int = 224,
        targetHeight: Int = 224,
        roi: ScanConfiguration.NormalizedRect? = null,
    ): List<Bitmap> {
        val n = maxOf(1, maxFrames)
        val file = File(filePath)
        if (!file.exists() || !file.isFile) return emptyList()

        val ext = file.extension.lowercase()
        val isGif = ext == "gif" || run {
            val header = ByteArray(4)
            try {
                FileInputStream(file).use { it.read(header) }
                header.startsWithBytes(GIF_MAGIC)
            } catch (_: Throwable) { false }
        }

        if (isGif) {
            val frames = sampleGifFrames(file, n, targetWidth, targetHeight)
            if (frames.isNotEmpty()) return applyRoiToAll(frames, roi)
            // fall through to single-frame fallback if Movie failed.
        }

        // Animated WebP / HEIF on API 28+: ImageDecoder gives us the first
        // frame as a Bitmap (or a static composited result for animated
        // sources). Multi-frame extraction is not exposed by the platform
        // without a third-party library.
        // TODO: add real per-frame extraction for animated WebP/HEIF when
        // we're willing to ship a WebP demuxer dependency.
        val single = decodeFirstFrameSafely(filePath, targetWidth, targetHeight)
            ?: return emptyList()
        return applyRoiToAll(listOf(single), roi)
    }

    // MARK: - GIF path (Movie)

    @Suppress("DEPRECATION")
    private fun sampleGifFrames(
        file: File,
        maxFrames: Int,
        targetWidth: Int,
        targetHeight: Int,
    ): List<Bitmap> {
        val movie: Movie = try {
            Movie.decodeFile(file.absolutePath) ?: return emptyList()
        } catch (t: Throwable) {
            Log.w(TAG, "Movie.decodeFile failed: ${t.message}")
            return emptyList()
        }

        val srcW = movie.width()
        val srcH = movie.height()
        if (srcW <= 0 || srcH <= 0) return emptyList()
        val duration = movie.duration()  // ms; 0 means "static GIF / unknown"

        // Choose an output bitmap size that fits within the target box while
        // preserving aspect ratio. ImageDecoder-style downsample isn't
        // available for Movie; we render into the target-sized bitmap and
        // let Canvas scale.
        val scale = minOf(
            targetWidth.toFloat() / srcW.toFloat(),
            targetHeight.toFloat() / srcH.toFloat(),
            1f,  // never upscale
        )
        val outW = maxOf(1, (srcW * scale).toInt())
        val outH = maxOf(1, (srcH * scale).toInt())

        val frames = ArrayList<Bitmap>(maxFrames)
        val frameCount = if (duration <= 0) 1 else maxFrames
        for (i in 0 until frameCount) {
            val timeMs = if (duration <= 0 || frameCount == 1) {
                0
            } else {
                // Evenly-spaced positions; the last sample sits just before
                // the end so we don't loop back to frame 0.
                ((duration.toLong() * i) / frameCount).toInt()
            }
            val bmp = renderGifFrame(movie, timeMs, outW, outH) ?: continue
            frames.add(bmp)
        }
        return frames
    }

    @Suppress("DEPRECATION")
    private fun renderGifFrame(
        movie: Movie,
        timeMs: Int,
        outW: Int,
        outH: Int,
    ): Bitmap? {
        var sampleDivisor = 1
        while (sampleDivisor <= 8) {
            try {
                val w = maxOf(1, outW / sampleDivisor)
                val h = maxOf(1, outH / sampleDivisor)
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                val srcW = movie.width()
                val srcH = movie.height()
                if (srcW > 0 && srcH > 0) {
                    val sx = w.toFloat() / srcW.toFloat()
                    val sy = h.toFloat() / srcH.toFloat()
                    canvas.save()
                    canvas.scale(sx, sy)
                    movie.setTime(timeMs)
                    movie.draw(canvas, 0f, 0f)
                    canvas.restore()
                } else {
                    movie.setTime(timeMs)
                    movie.draw(canvas, 0f, 0f)
                }
                return bmp
            } catch (oom: OutOfMemoryError) {
                Log.w(TAG, "GIF frame OOM at /$sampleDivisor — retrying smaller")
                sampleDivisor *= 2
            } catch (t: Throwable) {
                Log.w(TAG, "GIF frame render failed: ${t.message}")
                return null
            }
        }
        return null
    }

    // MARK: - First-frame fallback (ImageDecoder API 28+, BitmapFactory otherwise)

    private fun decodeFirstFrameSafely(
        filePath: String,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap? {
        // API 28+: ImageDecoder properly handles animated WebP/HEIF (returns
        // a static composited representation) and respects setTargetSize.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val source = ImageDecoder.createSource(File(filePath))
                return ImageDecoder.decodeBitmap(source) { decoder, _, _ ->
                    decoder.setTargetSize(targetWidth, targetHeight)
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    decoder.isMutableRequired = false
                }
            } catch (oom: OutOfMemoryError) {
                Log.w(TAG, "ImageDecoder OOM, falling back to BitmapFactory")
            } catch (t: Throwable) {
                Log.w(TAG, "ImageDecoder failed for $filePath: ${t.message}")
            }
        }

        // Fallback: two-pass BitmapFactory decode. For animated images this
        // returns the first frame on most Android versions.
        return decodeFirstFrameBitmapFactory(filePath, targetWidth, targetHeight)
    }

    private fun decodeFirstFrameBitmapFactory(
        filePath: String,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeFile(filePath, bounds)
        } catch (t: Throwable) {
            Log.w(TAG, "decodeFile bounds failed: ${t.message}")
            return null
        }
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        var sample = 1
        while (srcW / (sample * 2) >= targetWidth && srcH / (sample * 2) >= targetHeight) {
            sample *= 2
        }

        while (sample <= 32) {
            try {
                val opts = BitmapFactory.Options().apply {
                    inJustDecodeBounds = false
                    inSampleSize = sample
                    inPreferredConfig = Bitmap.Config.ARGB_8888
                }
                return BitmapFactory.decodeFile(filePath, opts)
            } catch (oom: OutOfMemoryError) {
                Log.w(TAG, "BitmapFactory OOM at sample=$sample — retrying smaller")
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

    // MARK: - Helpers

    private fun applyRoiToAll(
        frames: List<Bitmap>,
        roi: ScanConfiguration.NormalizedRect?,
    ): List<Bitmap> {
        if (roi == null || roi.isFull || !roi.isValid) return frames
        val out = ArrayList<Bitmap>(frames.size)
        for (frame in frames) {
            val cropped = cropToRoi(frame, roi)
            if (cropped !== frame) BitmapPipeline.recycleQuietly(frame)
            out.add(cropped)
        }
        return out
    }

    private fun cropToRoi(src: Bitmap, roi: ScanConfiguration.NormalizedRect): Bitmap {
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src
        val x = (roi.x * w).toInt().coerceIn(0, w - 1)
        val y = (roi.y * h).toInt().coerceIn(0, h - 1)
        val cw = (roi.width * w).toInt().coerceAtLeast(1).coerceAtMost(w - x)
        val ch = (roi.height * h).toInt().coerceAtLeast(1).coerceAtMost(h - y)
        return try {
            Bitmap.createBitmap(src, x, y, cw, ch)
        } catch (t: Throwable) {
            Log.w(TAG, "ROI crop $roi failed: ${t.message}")
            src
        }
    }

    private fun ByteArray.startsWithBytes(prefix: ByteArray): Boolean {
        if (this.size < prefix.size) return false
        for (i in prefix.indices) {
            if (this[i] != prefix[i]) return false
        }
        return true
    }
}
