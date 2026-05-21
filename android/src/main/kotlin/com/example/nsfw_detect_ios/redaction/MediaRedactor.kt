package com.example.nsfw_detect_ios.redaction

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/**
 * Detection-aware media redaction. Pendant to
 * `ios/Classes/redaction/MediaRedactor.swift`.
 *
 * Approximate-gaussian blur via downscale → upscale: cheap, vendor-agnostic,
 * and avoids the deprecated RenderScript path. Quality is good enough for
 * moderation review at the intensities the API surface allows.
 */
object MediaRedactor {

    enum class Mode { BLUR, PIXELATE, BLACK_BOX }

    /** Normalised [0, 1] coords with top-left origin (Dart wire shape). */
    data class Box(
        val x: Float,
        val y: Float,
        val width: Float,
        val height: Float,
    )

    fun fromString(s: String?): Mode = when (s) {
        "pixelate" -> Mode.PIXELATE
        "blackBox" -> Mode.BLACK_BOX
        else -> Mode.BLUR
    }

    fun redactBytes(
        input: ByteArray,
        boxes: List<Box>,
        mode: Mode,
        intensity: Float,
        outputFormat: String = "jpeg",
    ): ByteArray {
        val src = BitmapFactory.decodeByteArray(input, 0, input.size)
            ?: throw IllegalArgumentException("Could not decode image bytes")
        try {
            val output = renderRedacted(src, boxes, mode, intensity)
            val bos = ByteArrayOutputStream()
            val fmt = if (outputFormat.equals("png", ignoreCase = true)) {
                Bitmap.CompressFormat.PNG
            } else {
                Bitmap.CompressFormat.JPEG
            }
            output.compress(fmt, 92, bos)
            if (output !== src) output.recycle()
            return bos.toByteArray()
        } finally {
            if (!src.isRecycled) src.recycle()
        }
    }

    fun redactFile(
        inputPath: String,
        boxes: List<Box>,
        mode: Mode,
        intensity: Float,
        outputPath: String?,
    ): String {
        val bytes = File(inputPath).readBytes()
        val ext = inputPath.substringAfterLast('.', "").lowercase()
        val outputFormat = if (ext == "png") "png" else "jpeg"
        val redactedBytes = redactBytes(bytes, boxes, mode, intensity, outputFormat)
        val dest = outputPath ?: File(
            File(inputPath).parentFile ?: File("/data/local/tmp"),
            "nsfw_redacted_${System.currentTimeMillis()}.$outputFormat"
        ).absolutePath
        FileOutputStream(dest).use { it.write(redactedBytes) }
        return dest
    }

    private fun renderRedacted(
        src: Bitmap,
        boxes: List<Box>,
        mode: Mode,
        intensity: Float,
    ): Bitmap {
        val clamped = intensity.coerceIn(0f, 1f)
        val output = src.copy(Bitmap.Config.ARGB_8888, true)
            ?: throw IllegalStateException("copy() returned null — Bitmap unwritable")
        val canvas = Canvas(output)
        val w = output.width
        val h = output.height
        val rects: List<Box> = boxes.ifEmpty { listOf(Box(0f, 0f, 1f, 1f)) }
        for (b in rects) {
            val rect = Rect(
                (b.x * w).toInt().coerceIn(0, w),
                (b.y * h).toInt().coerceIn(0, h),
                ((b.x + b.width) * w).toInt().coerceIn(0, w),
                ((b.y + b.height) * h).toInt().coerceIn(0, h),
            )
            if (rect.width() <= 0 || rect.height() <= 0) continue
            when (mode) {
                Mode.BLUR -> applyBlur(canvas, src, rect, clamped)
                Mode.PIXELATE -> applyPixelate(canvas, src, rect, clamped)
                Mode.BLACK_BOX -> applyBlackBox(canvas, rect)
            }
        }
        return output
    }

    private fun applyBlur(canvas: Canvas, src: Bitmap, rect: Rect, intensity: Float) {
        // 2…32× downscale. Approximation of a gaussian; faster than RenderScript
        // and avoids the deprecation warning on Android 12+.
        val factor = (2 + (intensity * 30).toInt()).coerceAtLeast(2)
        var crop: Bitmap? = null
        var small: Bitmap? = null
        var blurred: Bitmap? = null
        try {
            crop = Bitmap.createBitmap(src, rect.left, rect.top, rect.width(), rect.height())
            val smallW = (crop.width / factor).coerceAtLeast(1)
            val smallH = (crop.height / factor).coerceAtLeast(1)
            small = Bitmap.createScaledBitmap(crop, smallW, smallH, true)
            blurred = Bitmap.createScaledBitmap(small, crop.width, crop.height, true)
            canvas.drawBitmap(blurred, rect.left.toFloat(), rect.top.toFloat(), null)
        } finally {
            if (crop != null && crop !== src && !crop.isRecycled) crop.recycle()
            if (small != null && small !== crop && !small.isRecycled) small.recycle()
            if (blurred != null && blurred !== small && !blurred.isRecycled) blurred.recycle()
        }
    }

    private fun applyPixelate(canvas: Canvas, src: Bitmap, rect: Rect, intensity: Float) {
        val blockSize = (4 + (intensity * 60).toInt()).coerceAtLeast(2)
        var crop: Bitmap? = null
        var small: Bitmap? = null
        var pixelated: Bitmap? = null
        try {
            crop = Bitmap.createBitmap(src, rect.left, rect.top, rect.width(), rect.height())
            val smallW = (crop.width / blockSize).coerceAtLeast(1)
            val smallH = (crop.height / blockSize).coerceAtLeast(1)
            // filter=false to keep hard mosaic edges.
            small = Bitmap.createScaledBitmap(crop, smallW, smallH, false)
            pixelated = Bitmap.createScaledBitmap(small, crop.width, crop.height, false)
            canvas.drawBitmap(pixelated, rect.left.toFloat(), rect.top.toFloat(), null)
        } finally {
            if (crop != null && crop !== src && !crop.isRecycled) crop.recycle()
            if (small != null && small !== crop && !small.isRecycled) small.recycle()
            if (pixelated != null && pixelated !== small && !pixelated.isRecycled) pixelated.recycle()
        }
    }

    private fun applyBlackBox(canvas: Canvas, rect: Rect) {
        val paint = Paint().apply {
            color = Color.BLACK
            style = Paint.Style.FILL
            isAntiAlias = false
        }
        canvas.drawRect(rect, paint)
    }
}
