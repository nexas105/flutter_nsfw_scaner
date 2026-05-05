package com.example.nsfw_detect_ios.camera

/**
 * Drops frames to enforce a target FPS ceiling regardless of the camera's
 * native delivery rate.
 *
 * `targetFps` is the upper bound from
 * [com.example.nsfw_detect_ios.camera.CameraSessionConfig.fps] (Phase-01
 * `CameraConfiguration.fps` — 1..30, default 2). Even with CameraX's
 * `STRATEGY_KEEP_ONLY_LATEST` the camera produces frames at ~30fps; this
 * throttle is what actually rate-limits inference.
 *
 * `config.fps = 10` -> `minIntervalMs = 100ms` -> at most 10 frames/sec
 * are accepted. `config.fps = 2` -> 500ms between accepted frames.
 *
 * Thread-safety: the analyzer calls [acceptFrame] from the single-thread
 * analysis executor only, so a single `@Volatile` long is sufficient. We
 * don't need atomic CAS here — racing readers/writers would at worst skip
 * or accept one extra frame, which is harmless.
 */
internal class FpsThrottle(targetFps: Int) {
    private val minIntervalMs: Long =
        (1000.0 / targetFps.coerceIn(1, 60)).toLong().coerceAtLeast(1L)

    @Volatile
    private var lastAcceptedMs: Long = 0L

    /**
     * Returns `true` if `nowMs` should be processed, `false` if it should
     * be dropped. On `true`, advances the internal clock to `nowMs`.
     */
    fun acceptFrame(nowMs: Long): Boolean {
        if (nowMs - lastAcceptedMs < minIntervalMs) return false
        lastAcceptedMs = nowMs
        return true
    }
}
