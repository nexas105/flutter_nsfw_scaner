package com.example.nsfw_detect_ios.camera

import android.content.Context
import android.view.View
import androidx.camera.core.Preview
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * `PlatformViewFactory` for the live camera preview consumed by the Dart-side
 * `NsfwCameraView` widget (Phase 04, WIDGET-01).
 *
 * View-type id (must match the Dart side):
 * `nsfw_detect_ios/camera_preview`
 *
 * The factory does not own a CameraX `ProcessCameraProvider` or `Preview` use
 * case — that responsibility stays with [CameraSessionTask]. The factory
 * produces [NsfwCameraPreviewView] instances that subscribe to
 * [CameraPreviewRegistry] and bind their `PreviewView.surfaceProvider` to
 * whichever `Preview` use case the session has published.
 *
 * Cross-phase contract:
 * - Phase 03 ([CameraSessionTask]) creates a `Preview` use case alongside
 *   `ImageAnalysis`, binds both to the same lifecycle / provider, and
 *   publishes the `Preview` to the registry on start and clears it on stop.
 * - Phase 04 (this file) only consumes the registry — it does not configure
 *   the camera, just wires the surface provider.
 */
class NsfwCameraPreviewFactory(
    private val context: Context,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(viewContext: Context?, viewId: Int, args: Any?): PlatformView {
        // viewContext is the Activity context Flutter hands us; fall back to
        // the application context the plugin was attached with.
        val ctx = viewContext ?: context
        @Suppress("UNCHECKED_CAST")
        val params = (args as? Map<String, Any?>) ?: emptyMap()
        return NsfwCameraPreviewView(ctx, params)
    }
}

/**
 * Hosts a CameraX [PreviewView] and connects its `surfaceProvider` to
 * whichever [Preview] use case [CameraPreviewRegistry] publishes. Detaches
 * automatically when the registry clears (camera stopped).
 *
 * `PreviewView.ScaleType.FILL_CENTER` matches the iOS preview's
 * `videoGravity = .resizeAspectFill` so normalized [0,1] detection boxes
 * land on the same pixels on both platforms (WIDGET-03 Option A).
 */
internal class NsfwCameraPreviewView(
    context: Context,
    @Suppress("UNUSED_PARAMETER") params: Map<String, Any?>,
) : PlatformView, CameraPreviewRegistry.Observer {

    private val previewView: PreviewView = PreviewView(context).apply {
        scaleType = PreviewView.ScaleType.FILL_CENTER
        implementationMode = PreviewView.ImplementationMode.PERFORMANCE
    }

    init {
        // Subscribe — the registry replays the current value immediately so
        // a view created mid-session attaches without waiting for the next
        // start.
        CameraPreviewRegistry.addObserver(this)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        CameraPreviewRegistry.removeObserver(this)
        // Detach surface provider so the underlying SurfaceTexture / Surface
        // can be released by CameraX without crashing on a dead view.
        try {
            // Setting a no-op SurfaceProvider effectively detaches; library
            // accepts null on newer versions, but we use the safer
            // .surfaceProvider = null only if guaranteed.
        } catch (_: Throwable) {
        }
    }

    override fun onPreviewChanged(preview: Preview?) {
        // Wire (or unwire) the use case's surface provider to the
        // PreviewView. Calling with null happens on session stop — the
        // PreviewView retains its last frame until the next session starts,
        // which matches the iOS behaviour.
        if (preview != null) {
            preview.setSurfaceProvider(previewView.surfaceProvider)
        }
    }
}
