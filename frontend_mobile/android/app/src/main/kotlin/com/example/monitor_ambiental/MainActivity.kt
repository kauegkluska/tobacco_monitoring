package com.example.monitor_ambiental

import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Abre as telas de configuração do Android quando o usuário negou uma permissão.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "monitor/settings")
            .setMethodCallHandler { call, result ->
                // Procurar o servidor por mDNS: sem esta trava o Android descarta pacotes multicast.
                if (call.method == "multicastLock") {
                    result.success(setMulticastLock(call.arguments == true))
                    return@setMethodCallHandler
                }
                val intent = when (call.method) {
                    "notifications" ->
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        } else {
                            appDetails()
                        }
                    "app" -> appDetails()
                    else -> null
                }
                if (intent == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                } catch (error: Exception) {
                    result.success(false)
                }
            }
    }

    private fun setMulticastLock(enable: Boolean): Boolean {
        return try {
            if (enable) {
                val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                val lock = multicastLock ?: wifi.createMulticastLock("monitor-estufa").also {
                    it.setReferenceCounted(false)
                    multicastLock = it
                }
                lock.acquire()
            } else {
                multicastLock?.takeIf { it.isHeld }?.release()
            }
            true
        } catch (error: Exception) {
            false
        }
    }

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun appDetails() =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
}
