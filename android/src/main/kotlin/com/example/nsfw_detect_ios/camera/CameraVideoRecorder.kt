package com.example.nsfw_detect_ios.camera

import android.graphics.Bitmap
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import com.example.nsfw_detect_ios.ml.NsfwLabel
import java.io.File

internal class CameraVideoRecorder(private val cacheDir: File) {

    private val lock = Any()
    private val bufferInfo = MediaCodec.BufferInfo()

    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var outputFile: File? = null
    private var trackIndex = -1
    private var muxerStarted = false
    private var width = 0
    private var height = 0
    private var startNanos = 0L

    @Volatile var isRecording = false
        private set

    @Volatile var triggeringLabels: List<NsfwLabel>? = null
        private set

    fun startIfNeeded(sample: Bitmap, labels: List<NsfwLabel>) = synchronized(lock) {
        if (isRecording) return

        val w = sample.width and 1.inv()
        val h = sample.height and 1.inv()
        if (w < 2 || h < 2) return

        val file = try {
            File.createTempFile("camrec_", ".mp4", cacheDir)
        } catch (t: Throwable) {
            Log.w(TAG, "temp file creation failed: ${t.message}")
            return
        }

        val format = MediaFormat.createVideoFormat(MIME, w, h).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, 2_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, NOMINAL_FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }

        try {
            val enc = MediaCodec.createEncoderByType(MIME)
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            val mux = MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            encoder = enc
            muxer = mux
        } catch (t: Throwable) {
            Log.w(TAG, "encoder init failed: ${t.message}")
            try { encoder?.release() } catch (_: Throwable) {}
            encoder = null
            muxer = null
            file.delete()
            return
        }

        outputFile = file
        width = w
        height = h
        trackIndex = -1
        muxerStarted = false
        startNanos = System.nanoTime()
        triggeringLabels = labels
        isRecording = true
        Log.i(TAG, "recording started → ${file.name} (${w}x$h)")
    }

    fun append(bitmap: Bitmap) = synchronized(lock) {
        val enc = encoder ?: return
        if (!isRecording) return
        if (bitmap.width < width || bitmap.height < height) return
        try {
            drain(endOfStream = false)
            val inIndex = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            if (inIndex < 0) return
            val image = enc.getInputImage(inIndex)
            val inputBuffer = enc.getInputBuffer(inIndex)
            if (image == null || inputBuffer == null) {
                enc.queueInputBuffer(inIndex, 0, 0, 0, 0)
                return
            }
            fillYuv420(image, bitmap)
            val ptsUs = (System.nanoTime() - startNanos) / 1_000L
            enc.queueInputBuffer(inIndex, 0, inputBuffer.capacity(), ptsUs, 0)
        } catch (t: Throwable) {
            Log.w(TAG, "append failed: ${t.message}")
        }
    }

    fun finish(): File? = synchronized(lock) {
        if (!isRecording) return null
        isRecording = false

        val enc = encoder
        val mux = muxer
        val file = outputFile

        try {
            if (enc != null) {
                val inIndex = enc.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (inIndex >= 0) {
                    enc.queueInputBuffer(
                        inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                    )
                }
                drain(endOfStream = true)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "finish drain failed: ${t.message}")
        }

        try { enc?.stop() } catch (_: Throwable) {}
        try { enc?.release() } catch (_: Throwable) {}
        try { if (muxerStarted) mux?.stop() } catch (_: Throwable) {}
        try { mux?.release() } catch (_: Throwable) {}
        encoder = null
        muxer = null

        if (!muxerStarted || file == null || !file.exists() || file.length() <= 0L) {
            file?.delete()
            return null
        }
        Log.i(TAG, "recording finished → ${file.name} (${file.length() / 1024} KB)")
        return file
    }

    private fun drain(endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return
        var iterations = 0
        while (true) {
            if (endOfStream && ++iterations > DRAIN_MAX_ITERATIONS) {
                Log.w(TAG, "drain exceeded iteration cap — giving up")
                return
            }
            val timeout = if (endOfStream) DEQUEUE_TIMEOUT_US else 0L
            val outIndex = enc.dequeueOutputBuffer(bufferInfo, timeout)
            when {
                outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!muxerStarted) {
                        trackIndex = mux.addTrack(enc.outputFormat)
                        mux.start()
                        muxerStarted = true
                    }
                }
                outIndex >= 0 -> {
                    val encoded = enc.getOutputBuffer(outIndex)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        bufferInfo.size = 0
                    }
                    if (encoded != null && bufferInfo.size > 0 && muxerStarted) {
                        encoded.position(bufferInfo.offset)
                        encoded.limit(bufferInfo.offset + bufferInfo.size)
                        mux.writeSampleData(trackIndex, encoded, bufferInfo)
                    }
                    enc.releaseOutputBuffer(outIndex, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private fun fillYuv420(image: Image, bitmap: Bitmap) {
        val bw = bitmap.width
        val argb = IntArray(bw * height)
        bitmap.getPixels(argb, 0, bw, 0, 0, width, height)

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer

        for (row in 0 until height) {
            for (col in 0 until width) {
                val c = argb[row * bw + col]
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF

                val y = clamp(((66 * r + 129 * g + 25 * b + 128) shr 8) + 16)
                yBuf.put(row * yPlane.rowStride + col * yPlane.pixelStride, y.toByte())

                if (row and 1 == 0 && col and 1 == 0) {
                    val u = clamp(((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128)
                    val v = clamp(((112 * r - 94 * g - 18 * b + 128) shr 8) + 128)
                    val uvRow = row shr 1
                    val uvCol = col shr 1
                    uBuf.put(uvRow * uPlane.rowStride + uvCol * uPlane.pixelStride, u.toByte())
                    vBuf.put(uvRow * vPlane.rowStride + uvCol * vPlane.pixelStride, v.toByte())
                }
            }
        }
    }

    private fun clamp(v: Int): Int = if (v < 0) 0 else if (v > 255) 255 else v

    private companion object {
        const val TAG = "NSFW-Camera-Recorder"
        const val MIME = "video/avc"
        const val NOMINAL_FPS = 15
        const val DEQUEUE_TIMEOUT_US = 10_000L
        const val DRAIN_MAX_ITERATIONS = 200
    }
}
