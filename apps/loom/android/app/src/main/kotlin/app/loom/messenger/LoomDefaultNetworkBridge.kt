package app.loom.messenger

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Emits only a monotonic invalidation generation plus coarse diagnostics.
 *
 * It deliberately does not expose SSID, IP/MAC addresses, DNS servers, or a
 * boolean that the Dart routing layer could mistake for proof of reachability.
 */
class LoomDefaultNetworkBridge(context: Context) : EventChannel.StreamHandler {
    private val connectivity =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var registered = false
    private var generation = 0L
    private var currentNetwork: Network? = null
    private var capabilityFingerprint: String? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (currentNetwork != network) {
                currentNetwork = network
                capabilityFingerprint = null
                generation += 1
                emit(transport = "unknown", validated = null)
            }
        }

        override fun onLost(network: Network) {
            if (currentNetwork != network) return
            currentNetwork = null
            capabilityFingerprint = null
            generation += 1
            emit(transport = "none", validated = false)
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            if (currentNetwork != network) return
            val transport = transportClass(networkCapabilities)
            val validated = networkCapabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED,
            )
            val nextFingerprint = "$transport:$validated"
            val previous = capabilityFingerprint
            capabilityFingerprint = nextFingerprint
            if (previous != null && previous != nextFingerprint) {
                // A material default-network capability/transport transition
                // invalidates socket assumptions even when Network is reused.
                generation += 1
            }
            emit(transport = transport, validated = validated)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (registered) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            // Default-network callbacks are unavailable before API 24. Send
            // remains correct because transport deadlines still bound failure.
            emit(transport = "unknown", validated = null)
            return
        }
        connectivity.registerDefaultNetworkCallback(callback)
        registered = true
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        unregister()
    }

    fun shutdown() {
        sink = null
        unregister()
    }

    private fun unregister() {
        if (!registered) return
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (_: RuntimeException) {
            // Best-effort Activity teardown.
        }
        registered = false
        currentNetwork = null
        capabilityFingerprint = null
    }

    private fun emit(transport: String, validated: Boolean?) {
        val payload = hashMapOf<String, Any>(
            "generation" to generation,
            "transport" to transport,
        )
        if (validated != null) payload["validated"] = validated
        mainHandler.post {
            sink?.success(payload)
        }
    }

    private fun transportClass(capabilities: NetworkCapabilities): String = when {
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "unknown"
    }

    companion object {
        const val CHANNEL = "loom/default_network"
    }
}
