package com.ahmed.tartilaa

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL_NAME = "quran_app/native_speech"
        private const val EVENT_CHANNEL_NAME = "quran_app/native_speech/events"
        private const val AUDIO_PERMISSION_REQUEST_CODE = 12034
    }

    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var speech: ContinuousSpeechController? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return AudioServicePlugin.getFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        speech = ContinuousSpeechController(applicationContext) { event ->
            runOnUiThread { eventSink?.success(event) }
        }

        MethodChannel(messenger, METHOD_CHANNEL_NAME).setMethodCallHandler(
            this::onMethodCall
        )
        EventChannel(messenger, EVENT_CHANNEL_NAME).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val controller = speech
        when (call.method) {
            "isAvailable" -> result.success(controller?.isAvailable() ?: false)
            "hasPermission" -> result.success(controller?.hasPermission() ?: false)
            "requestPermission" -> requestPermission(result)
            "startListening" -> {
                if (controller == null) {
                    result.error("not_ready", "Speech controller is not initialized.", null)
                    return
                }
                val locale = call.argument<String>("locale") ?: "ar"
                val partialResults = call.argument<Boolean>("partialResults") ?: true
                val continuous = call.argument<Boolean>("continuous") ?: false
                val err = controller.start(
                    locale = locale,
                    partialResults = partialResults,
                    continuous = continuous,
                )
                if (err == null) {
                    result.success(null)
                } else {
                    result.error(err.first, err.second, null)
                }
            }
            "stopListening" -> {
                controller?.stop()
                result.success(null)
            }
            "cancelListening" -> {
                controller?.cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasAudioPermission()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "Another permission request is already active.",
                null
            )
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            AUDIO_PERMISSION_REQUEST_CODE
        )
    }

    private fun hasAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != AUDIO_PERMISSION_REQUEST_CODE) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    override fun onDestroy() {
        speech?.destroy()
        speech = null
        super.onDestroy()
    }
}
