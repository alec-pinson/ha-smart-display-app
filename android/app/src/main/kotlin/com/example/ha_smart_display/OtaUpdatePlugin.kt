package com.example.ha_smart_display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.app.PendingIntent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class OtaUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    companion object {
        private const val ACTION_INSTALL_COMPLETE = "com.example.ha_smart_display.INSTALL_COMPLETE"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ha_smart_display/ota")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val filePath = call.argument<String>("filePath")
                if (filePath == null) {
                    result.error("INVALID_ARGS", "filePath required", null)
                    return
                }
                installApk(filePath, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(filePath: String, result: MethodChannel.Result) {
        val file = File(filePath)
        if (!file.exists()) {
            result.error("FILE_NOT_FOUND", "APK not found at $filePath", null)
            return
        }

        val packageInstaller = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        val sessionId: Int
        val session: PackageInstaller.Session
        try {
            sessionId = packageInstaller.createSession(params)
            session = packageInstaller.openSession(sessionId)
        } catch (e: Exception) {
            result.error("SESSION_ERROR", e.message, null)
            return
        }

        try {
            session.openWrite("package", 0, file.length()).use { output ->
                FileInputStream(file).use { input -> input.copyTo(output) }
                session.fsync(output)
            }

            val intent = Intent(ACTION_INSTALL_COMPLETE)
            val pendingIntent = PendingIntent.getBroadcast(
                context, sessionId, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context, i: Intent) {
                    ctx.unregisterReceiver(this)
                    val status = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
                    if (status == PackageInstaller.STATUS_SUCCESS) {
                        result.success(null)
                    } else {
                        val msg = i.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Unknown error"
                        result.error("INSTALL_FAILED", msg, null)
                    }
                }
            }

            // RECEIVER_NOT_EXPORTED = 4 (API 33+); safe to pass 0 on older APIs
            val flags = if (android.os.Build.VERSION.SDK_INT >= 33) 4 else 0
            context.registerReceiver(receiver, IntentFilter(ACTION_INSTALL_COMPLETE), null, null, flags)

            session.commit(pendingIntent.intentSender)
        } catch (e: Exception) {
            session.abandon()
            result.error("INSTALL_ERROR", e.message, null)
        }
    }
}
