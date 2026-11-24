package com.netpulse.netpulse_router_manager

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets the app (connection test, error messages) know whether
        // traffic is pinned to the home Wi-Fi.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "netpulse/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(
                        mapOf("boundToWifi" to (WifiBinder.boundNetwork != null))
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
