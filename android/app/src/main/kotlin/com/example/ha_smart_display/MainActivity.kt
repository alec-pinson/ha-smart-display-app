package com.example.ha_smart_display

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val systemChannel = "ha_smart_display/system"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register mDNS plugin
        flutterEngine.plugins.add(MdnsPlugin())

        // System channel — brightness control
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBrightness" -> {
                        val brightness = (call.argument<Double>("brightness") ?: 0.5)
                            .coerceIn(0.0, 1.0).toFloat()
                        try {
                            val lp = window.attributes
                            lp.screenBrightness = brightness
                            window.attributes = lp
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("BRIGHTNESS_ERROR", e.message, null)
                        }
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
}
