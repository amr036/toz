package com.netpulse.netpulse_router_manager

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/**
 * Keeps the whole app process on the home Wi-Fi.
 *
 * When Android decides the Wi-Fi has no internet (ISP line down, quota used
 * up, or this phone's own internet was cut by the app), it moves the default
 * route to mobile data. Requests to the router (192.168.1.1) then leave over
 * 4G and time out. Binding the process to the Wi-Fi network keeps router
 * traffic on the LAN. Runs for the UI and for the WorkManager background
 * sync, because both live in this process.
 */
class NetPulseApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        WifiBinder.start(this)
    }
}

object WifiBinder {
    private const val TAG = "NetPulseWifi"

    @Volatile
    var boundNetwork: Network? = null
        private set

    private var started = false

    @Synchronized
    fun start(app: Application) {
        if (started) return
        started = true
        val cm = app.getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // Also match Wi-Fi that Android flags as having no internet.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    boundNetwork = network
                    val ok = cm.bindProcessToNetwork(network)
                    Log.i(TAG, "Bound app to Wi-Fi network $network: $ok")
                }

                override fun onLost(network: Network) {
                    if (network == boundNetwork) {
                        boundNetwork = null
                        cm.bindProcessToNetwork(null)
                        Log.i(TAG, "Wi-Fi lost, unbound")
                    }
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "Could not watch Wi-Fi: $e")
        }
    }
}
