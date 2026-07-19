package com.alecpinson.ha_smart_display

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

private const val TAG = "CameraAnalysis"

/**
 * Reads the device's hardware ambient light sensor and publishes lux readings
 * via EventChannel `ha_smart_display/camera_analysis_events`.
 *
 * Motion detection was attempted via Camera2 and Camera1 APIs but the camera
 * is not accessible on this LineageOS build (cameraIdList = [], getNumberOfCameras() = 0).
 */
class CameraAnalysisPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private var sensorManager: SensorManager? = null
    private var lightSensor: Sensor? = null
    private var lastLux: Double? = null

    private val lightListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            lastLux = event.values[0].toDouble()
            emitReading()
        }
        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "ha_smart_display/camera_analysis")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "ha_smart_display/camera_analysis_events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Emit immediately if we already have a reading.
        lastLux?.let { emitReading() }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> { start(); result.success(null) }
            "stop" -> { stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun start() {
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        if (sensorManager == null) {
            Log.w(TAG, "SensorManager not available")
            return
        }
        lightSensor = sensorManager!!.getDefaultSensor(Sensor.TYPE_LIGHT)
        if (lightSensor == null) {
            Log.w(TAG, "No hardware light sensor")
            return
        }
        sensorManager!!.registerListener(lightListener, lightSensor, SensorManager.SENSOR_DELAY_NORMAL)
        Log.d(TAG, "Light sensor started: ${lightSensor!!.name}")
    }

    private fun stop() {
        sensorManager?.unregisterListener(lightListener)
        sensorManager = null
        lightSensor = null
    }

    private fun emitReading() {
        val lux = lastLux ?: return
        val json = JSONObject().apply {
            put("lux", lux)
        }.toString()
        mainHandler.post { eventSink?.success(json) }
    }
}
