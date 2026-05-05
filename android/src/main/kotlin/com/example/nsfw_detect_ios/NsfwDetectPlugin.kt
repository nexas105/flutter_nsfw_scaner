package com.example.nsfw_detect_ios

import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * NsfwDetectPlugin — Flutter plugin entry point.
 * Implements FlutterPlugin, ActivityAware, and RequestPermissionsResultListener
 * to support runtime permission requests forwarded from ScanMethodHandler.
 */
class NsfwDetectPlugin : FlutterPlugin, ActivityAware, PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var scanEventSink: ScanEventSink
    private lateinit var scanMethodHandler: ScanMethodHandler

    private var activityBinding: ActivityPluginBinding? = null

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scanEventSink = ScanEventSink()
        scanMethodHandler = ScanMethodHandler(binding.applicationContext, scanEventSink)

        methodChannel = MethodChannel(binding.binaryMessenger, ChannelConstants.METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(scanMethodHandler)

        eventChannel = EventChannel(binding.binaryMessenger, ChannelConstants.EVENT_CHANNEL)
        eventChannel.setStreamHandler(scanEventSink)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // MARK: - ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        scanMethodHandler.activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        scanMethodHandler.activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        scanMethodHandler.activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        scanMethodHandler.activity = null
    }

    // MARK: - RequestPermissionsResultListener

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        return scanMethodHandler.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    // MARK: - ActivityResultListener

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?): Boolean {
        return scanMethodHandler.onActivityResult(requestCode, resultCode, data)
    }

    // MARK: - V1 Embedding Compatibility

    companion object {
        @JvmStatic
        @Suppress("DEPRECATION")
        fun registerWith(registrar: PluginRegistry.Registrar) {
            val plugin = NsfwDetectPlugin()
            val scanEventSink = ScanEventSink()
            val scanMethodHandler = ScanMethodHandler(registrar.context(), scanEventSink)

            val methodChannel = MethodChannel(registrar.messenger(), ChannelConstants.METHOD_CHANNEL)
            methodChannel.setMethodCallHandler(scanMethodHandler)

            val eventChannel = EventChannel(registrar.messenger(), ChannelConstants.EVENT_CHANNEL)
            eventChannel.setStreamHandler(scanEventSink)

            registrar.addRequestPermissionsResultListener { requestCode, permissions, grantResults ->
                scanMethodHandler.onRequestPermissionsResult(requestCode, permissions, grantResults)
            }
        }
    }
}
