package com.example.nsfw_detect_ios.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import androidx.camera.core.ImageProxy
import java.io.ByteArrayOutputStream

/**
 * Converts a CameraX [ImageProxy] (`YUV_420_888`) into an upright
 * `ARGB_8888` [Bitmap] so the existing
 * [com.example.nsfw_detect_ios.ml.TFLiteEngine.classify] /
 * [com.example.nsfw_detect_ios.ml.MLDetectorEngine.detect] paths run
 * unchanged. **No second preprocessing implementation** — this helper's
 * only job is producing a Bitmap; resize / normalisation / softmax all
 * stay inside the engine.
 *
 * Approach:
 *  1. Compose the `YUV_420_888` planes into NV21 (Y intact + V/U
 *     interleaved chroma).
 *  2. JPEG-compress the NV21 buffer via [YuvImage] (the standard
 *     CameraX recipe — RenderScript would be faster but it's deprecated
 *     and not worth the API surface for a 10fps pipeline).
 *  3. Decode the JPEG bytes back as `ARGB_8888`.
 *  4. Apply the `imageInfo.rotationDegrees` rotation so the bitmap is
 *     upright (front-camera mirroring is left to downstream — it
 *     doesn't change classification results meaningfully).
 *
 * The returned Bitmap is independent of the [ImageProxy] — closing the
 * proxy after this call does **not** invalidate the bitmap.
 * `ImageProxy.close()` is the caller's responsibility (see
 * AND-CAM-09 / [CameraFrameAnalyzer.analyze]).
 */
internal object ImageProxyConverter {

    fun toBitmap(imageProxy: ImageProxy): Bitmap? {
        if (imageProxy.format != ImageFormat.YUV_420_888) return null
        val nv21 = yuv420ToNv21(imageProxy) ?: return null

        val yuvImage = YuvImage(
            nv21,
            ImageFormat.NV21,
            imageProxy.width,
            imageProxy.height,
            null,
        )
        val baos = ByteArrayOutputStream()
        if (!yuvImage.compressToJpeg(
                Rect(0, 0, imageProxy.width, imageProxy.height),
                90,
                baos,
            )
        ) return null

        val bytes = baos.toByteArray()
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null

        val rotation = imageProxy.imageInfo.rotationDegrees
        if (rotation == 0) return decoded

        val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
        return try {
            Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
        } catch (_: Throwable) {
            // If rotation allocation fails for any reason, fall back to the
            // un-rotated bitmap rather than dropping the frame entirely.
            decoded
        }
    }

    /**
     * Standard CameraX `YUV_420_888` -> NV21 byte interleave. Y plane is
     * copied intact; the chroma plane is V then U interleaved.
     *
     * NV21 layout:
     *  [Y0 Y1 Y2 ... | V0 U0 V1 U1 V2 U2 ...]
     *
     * `YUV_420_888` may have non-zero `pixelStride` and `rowStride` on the
     * chroma planes (some devices pack U+V interleaved already, others
     * don't). We handle both by copying row-by-row with the correct
     * strides.
     */
    private fun yuv420ToNv21(image: ImageProxy): ByteArray? {
        return try {
            val width = image.width
            val height = image.height
            val ySize = width * height
            val uvSize = width * height / 2
            val nv21 = ByteArray(ySize + uvSize)

            val planes = image.planes
            if (planes.size < 3) return null

            // ── Y plane ──────────────────────────────────────────────
            val yPlane = planes[0]
            val yBuffer = yPlane.buffer
            val yRowStride = yPlane.rowStride
            val yPixelStride = yPlane.pixelStride
            var pos = 0
            if (yPixelStride == 1 && yRowStride == width) {
                // Tightly-packed Y — single bulk copy.
                yBuffer.get(nv21, 0, ySize)
                pos = ySize
            } else {
                // Walk row-by-row and pixel-by-pixel.
                val rowData = ByteArray(yRowStride)
                for (row in 0 until height) {
                    val rowStart = row * yRowStride
                    yBuffer.position(rowStart)
                    val bytesToRead = minOf(yRowStride, yBuffer.remaining())
                    yBuffer.get(rowData, 0, bytesToRead)
                    if (yPixelStride == 1) {
                        System.arraycopy(rowData, 0, nv21, pos, width)
                        pos += width
                    } else {
                        var idx = 0
                        for (col in 0 until width) {
                            nv21[pos++] = rowData[idx]
                            idx += yPixelStride
                        }
                    }
                }
            }

            // ── UV plane (NV21 = V first, then U) ────────────────────
            val uPlane = planes[1]
            val vPlane = planes[2]
            val uBuffer = uPlane.buffer
            val vBuffer = vPlane.buffer
            val uRowStride = uPlane.rowStride
            val vRowStride = vPlane.rowStride
            val uPixelStride = uPlane.pixelStride
            val vPixelStride = vPlane.pixelStride

            val chromaHeight = height / 2
            val chromaWidth = width / 2
            for (row in 0 until chromaHeight) {
                for (col in 0 until chromaWidth) {
                    val vIdx = row * vRowStride + col * vPixelStride
                    val uIdx = row * uRowStride + col * uPixelStride
                    if (vIdx >= vBuffer.limit() || uIdx >= uBuffer.limit()) continue
                    nv21[pos++] = vBuffer.get(vIdx)
                    nv21[pos++] = uBuffer.get(uIdx)
                }
            }

            nv21
        } catch (_: Throwable) {
            null
        }
    }
}
