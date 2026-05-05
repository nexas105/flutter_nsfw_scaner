package com.example.nsfw_detect_ios.camera

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry

/**
 * Synthetic [LifecycleOwner] the plugin drives manually so the camera session
 * is **not** tied to the host [android.app.Activity]'s lifecycle. The plugin
 * moves it to [Lifecycle.State.STARTED] when the camera scan starts and to
 * [Lifecycle.State.DESTROYED] when it stops.
 *
 * CameraX requires a [LifecycleOwner] for `bindToLifecycle`. We don't want to
 * bind to the host Activity's lifecycle because that would couple our camera
 * state to host backgrounding / foregrounding decisions. Owning the lifecycle
 * here keeps `startCameraScan` / `stopCameraScan` in full control of the
 * pipeline and matches the iOS phase's expectation that the plugin is the
 * single authority over the camera session.
 */
internal class PluginLifecycleOwner : LifecycleOwner {
    private val registry = LifecycleRegistry(this)

    init {
        registry.currentState = Lifecycle.State.INITIALIZED
    }

    override val lifecycle: Lifecycle get() = registry

    /** Move to STARTED. Safe to call once per owner instance. */
    fun start() {
        registry.currentState = Lifecycle.State.STARTED
    }

    /**
     * Move to DESTROYED. Once destroyed the registry rejects further state
     * transitions, so a fresh [PluginLifecycleOwner] must be constructed for
     * the next session — see [com.example.nsfw_detect_ios.camera.CameraSessionTask].
     */
    fun stop() {
        registry.currentState = Lifecycle.State.DESTROYED
    }
}
