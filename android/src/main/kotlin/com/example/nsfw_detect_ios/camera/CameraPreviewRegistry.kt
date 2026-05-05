package com.example.nsfw_detect_ios.camera

import androidx.camera.core.Preview

/**
 * Cross-cutting registry that publishes the *currently active* CameraX
 * [Preview] use case so the Flutter `PlatformView` factory can attach a
 * `PreviewView` (and its `surfaceProvider`) to the same camera pipeline
 * that [CameraSessionTask] is using for `ImageAnalysis`.
 *
 * Why one registry instead of just exposing the field on the session task:
 * - `NsfwDetectPlugin.onAttachedToEngine` registers the platform-view
 *   factory once, eagerly. The factory must be able to find the *current*
 *   session whenever a `NsfwCameraView` is created — the session itself is
 *   short-lived (one per startCameraScan).
 *
 * Lifecycle:
 * - [CameraSessionTask] calls [set] right after binding `Preview` to the
 *   provider, and [clear] in its `stop()`.
 * - `NsfwCameraPreviewView` listens via [addObserver]; the most recent
 *   value is replayed immediately so a view created mid-session paints
 *   straight away.
 *
 * All access is from the main thread (CameraX bind / unbind happens on
 * Main; observer callbacks attach `surfaceProvider` which is also a UI
 * concern). This object is intentionally not thread-safe — call from
 * Main only.
 */
internal object CameraPreviewRegistry {

    interface Observer {
        fun onPreviewChanged(preview: Preview?)
    }

    private var current: Preview? = null
    private val observers: MutableList<java.lang.ref.WeakReference<Observer>> = mutableListOf()

    fun set(preview: Preview) {
        current = preview
        prune()
        observers.forEach { it.get()?.onPreviewChanged(preview) }
    }

    fun clear() {
        current = null
        prune()
        observers.forEach { it.get()?.onPreviewChanged(null) }
    }

    fun preview(): Preview? = current

    fun addObserver(observer: Observer) {
        prune()
        if (observers.any { it.get() === observer }) return
        observers.add(java.lang.ref.WeakReference(observer))
        observer.onPreviewChanged(current) // replay
    }

    fun removeObserver(observer: Observer) {
        observers.removeAll { it.get() === observer || it.get() == null }
    }

    private fun prune() {
        observers.removeAll { it.get() == null }
    }
}
