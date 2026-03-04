package com.example.ha_smart_display

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MdnsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ha_smart_display/mdns")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        stopAdvertising()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "advertise" -> {
                val serviceType = call.argument<String>("serviceType") ?: "_ha_smart_display._tcp"
                val serviceName = call.argument<String>("serviceName") ?: "ha_smart_display"
                val port = call.argument<Int>("port") ?: 8472
                val txtRecords = call.argument<Map<String, String>>("txtRecords") ?: emptyMap()
                advertise(serviceType, serviceName, port, txtRecords, result)
            }
            "stop" -> {
                stopAdvertising()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun advertise(
        serviceType: String,
        serviceName: String,
        port: Int,
        txtRecords: Map<String, String>,
        result: MethodChannel.Result
    ) {
        stopAdvertising()

        val ctx = context ?: run {
            result.error("NO_CONTEXT", "No application context", null)
            return
        }

        val nsd = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
        nsdManager = nsd

        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = serviceType
            this.port = port
            // Set TXT records (attributes) for device_id etc.
            for ((k, v) in txtRecords) {
                setAttribute(k, v)
            }
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i("MdnsPlugin", "mDNS registered: ${info.serviceName}")
                result.success(null)
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e("MdnsPlugin", "mDNS registration failed: $errorCode")
                result.error("MDNS_ERROR", "Registration failed: $errorCode", null)
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i("MdnsPlugin", "mDNS unregistered")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e("MdnsPlugin", "mDNS unregistration failed: $errorCode")
            }
        }

        registrationListener = listener
        nsd.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun stopAdvertising() {
        val listener = registrationListener ?: return
        try {
            nsdManager?.unregisterService(listener)
        } catch (e: Exception) {
            Log.w("MdnsPlugin", "Error stopping mDNS: ${e.message}")
        }
        registrationListener = null
        nsdManager = null
    }
}
