package com.alecpinson.ha_smart_display

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SYSTEM_CHANNEL_NAME = "ha_smart_display/system"
    private var systemMethodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register mDNS plugin
        flutterEngine.plugins.add(MdnsPlugin())

        // Register wake word plugin
        flutterEngine.plugins.add(WakeWordPlugin())

        // Register camera analysis plugin (lux + motion detection)
        flutterEngine.plugins.add(CameraAnalysisPlugin())

        // Register OTA update plugin
        flutterEngine.plugins.add(OtaUpdatePlugin())

        // System channel — brightness + volume control
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL_NAME)
        systemMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        // Negative value means auto brightness (BRIGHTNESS_OVERRIDE_NONE = -1f).
                        // Minimum usable positive value is 10/255 ≈ 0.039 — below this Android
                        // falls back to system/automatic brightness unexpectedly.
                        val raw = call.argument<Double>("brightness") ?: 0.5
                        val brightness = if (raw < 0) -1f
                            else raw.coerceIn(10.0 / 255.0, 1.0).toFloat()
                        try {
                            val lp = window.attributes
                            lp.screenBrightness = brightness
                            window.attributes = lp
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("BRIGHTNESS_ERROR", e.message, null)
                        }
                    }
                    "setVolume" -> {
                        val pct = (call.argument<Int>("volume") ?: 50).coerceIn(0, 100)
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val index = (pct / 100.0 * max).toInt().coerceIn(0, max)
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
                        result.success(null)
                    }
                    "getVolume" -> {
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        val pct = if (max > 0) (current * 100.0 / max).toInt() else 0
                        result.success(pct)
                    }
                    "restart" -> {
                        result.success(null)
                        Handler(Looper.getMainLooper()).postDelayed({
                            Process.killProcess(Process.myPid())
                        }, 100)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep screen on at the window level as a belt-and-suspenders backup
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            systemMethodChannel?.invokeMethod("onTrimMemory", level)
        }
    }
}
