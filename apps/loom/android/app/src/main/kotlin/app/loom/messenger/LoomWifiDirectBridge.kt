package app.loom.messenger

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android Wi-Fi Direct bearer for Loom Architecture v2.
 *
 * Discovery uses Wi-Fi P2P DNS-SD. TXT records contain only a short digest of
 * the caller-supplied rotating rendezvous value and a dynamic TCP port. Device
 * addresses stay inside this bridge and are represented in Dart by random,
 * short-lived handles. The TCP stream is a raw bearer and MUST still be wrapped
 * by Loom peer authentication/encryption before any DTN frame is trusted.
 */
class LoomWifiDirectBridge(
    private val activity: Activity,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()
    private val manager = activity.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val channel = manager?.initialize(activity, Looper.getMainLooper(), null)
    private val candidates = ConcurrentHashMap<String, Candidate>()
    private val links = ConcurrentHashMap<String, LinkState>()
    private val acceptedLinks = LinkedBlockingQueue<String>()
    private val scanning = AtomicBoolean(false)
    private val advertising = AtomicBoolean(false)

    @Volatile
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile
    private var pendingReadyResult: MethodChannel.Result? = null

    @Volatile
    private var activeServiceRequest: WifiP2pDnsSdServiceRequest? = null

    @Volatile
    private var localServiceInfo: WifiP2pDnsSdServiceInfo? = null

    @Volatile
    private var serverSocket: ServerSocket? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "supported" -> {
                result.success(isSupported())
                return true
            }
            "requestPermissions" -> {
                requestPermissions(result)
                return true
            }
            "ensureReady" -> {
                ensureReady(result)
                return true
            }
            "scan" -> {
                val timeoutMs = boundedTimeout(call.argument<Number>("timeoutMs")?.toLong(), 8_000L)
                startScan(timeoutMs, result)
                return true
            }
            "advertise" -> {
                val rendezvousId = call.argument<String>("rendezvousId")
                if (rendezvousId == null || rendezvousId.length !in 16..128) {
                    result.error("invalid_advertisement", "Invalid rotating rendezvous identifier", null)
                } else {
                    startAdvertising(rendezvousId, result)
                }
                return true
            }
            "stopAdvertising" -> {
                stopAdvertising()
                result.success(null)
                return true
            }
            "connect" -> {
                val nativeHandle = call.argument<String>("nativeHandle")
                if (nativeHandle.isNullOrBlank()) {
                    result.error("invalid_candidate", "Missing Wi-Fi Direct candidate handle", null)
                } else {
                    connect(nativeHandle, result)
                }
                return true
            }
            "accept" -> {
                val timeoutMs = boundedTimeout(call.argument<Number>("timeoutMs")?.toLong(), 1_000L)
                accept(timeoutMs, result)
                return true
            }
            "send" -> {
                val linkHandle = call.argument<String>("linkHandle")
                val bytes = call.argument<ByteArray>("bytes")
                if (linkHandle.isNullOrBlank() || bytes == null) {
                    result.error("invalid_send", "Missing Wi-Fi Direct link or frame", null)
                } else {
                    send(linkHandle, bytes, result)
                }
                return true
            }
            "receive" -> {
                val linkHandle = call.argument<String>("linkHandle")
                val timeoutMs = boundedTimeout(call.argument<Number>("timeoutMs")?.toLong(), 30_000L)
                if (linkHandle.isNullOrBlank()) {
                    result.error("invalid_receive", "Missing Wi-Fi Direct link handle", null)
                } else {
                    receive(linkHandle, timeoutMs, result)
                }
                return true
            }
            "close" -> {
                val linkHandle = call.argument<String>("linkHandle")
                if (!linkHandle.isNullOrBlank()) closeLink(linkHandle)
                result.success(null)
                return true
            }
            "startForegroundMode" -> {
                startForegroundMode()
                result.success(null)
                return true
            }
            "stopForegroundMode" -> {
                activity.stopService(Intent(activity, NearbyForegroundService::class.java))
                result.success(null)
                return true
            }
            else -> return false
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_PERMISSIONS) return false
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        if (pending != null) {
            val granted = grantResults.isNotEmpty() && grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            }
            postResult { pending.success(granted && hasRequiredPermissions()) }
        }
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_WIFI_SETTINGS) return false
        val pending = pendingReadyResult
        pendingReadyResult = null
        if (pending != null) {
            postResult { pending.success(hasRequiredPermissions() && isWifiEnabled()) }
        }
        return true
    }

    fun shutdown() {
        stopScanInternal()
        stopAdvertising()
        links.keys.toList().forEach(::closeLink)
        candidates.clear()
        ioExecutor.shutdownNow()
        pendingPermissionResult?.let { pending ->
            postResult {
                pending.error(
                    "activity_closed",
                    "Wi-Fi Direct permission request was interrupted",
                    null,
                )
            }
        }
        pendingPermissionResult = null
        pendingReadyResult?.let { pending ->
            postResult {
                pending.error(
                    "activity_closed",
                    "Wi-Fi settings request was interrupted",
                    null,
                )
            }
        }
        pendingReadyResult = null
    }

    private fun isSupported(): Boolean =
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT) &&
            manager != null && channel != null

    private fun requestPermissions(result: MethodChannel.Result) {
        if (hasRequiredPermissions()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_busy", "A Wi-Fi permission request is already active", null)
            return
        }
        val missing = requiredPermissions().filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
    }

    private fun ensureReady(result: MethodChannel.Result) {
        if (!isSupported()) {
            result.error("wifi_direct_unsupported", "Wi-Fi Direct is not supported", null)
            return
        }
        if (!hasRequiredPermissions()) {
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
            return
        }
        if (isWifiEnabled()) {
            result.success(true)
            return
        }
        if (pendingReadyResult != null) {
            result.error("wifi_settings_busy", "A Wi-Fi settings request is already active", null)
            return
        }
        pendingReadyResult = result
        try {
            val action = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Settings.Panel.ACTION_WIFI
            } else {
                Settings.ACTION_WIFI_SETTINGS
            }
            activity.startActivityForResult(Intent(action), REQUEST_WIFI_SETTINGS)
        } catch (_: Throwable) {
            pendingReadyResult = null
            result.error("wifi_settings_unavailable", "Unable to open Android Wi-Fi settings", null)
        }
    }

    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasRequiredPermissions(): Boolean = requiredPermissions().all {
        activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun isWifiEnabled(): Boolean {
        val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        return wifi?.isWifiEnabled == true
    }

    private fun requireReady(result: MethodChannel.Result): Pair<WifiP2pManager, WifiP2pManager.Channel>? {
        if (!isSupported()) {
            result.error("wifi_direct_unsupported", "Wi-Fi Direct is not supported", null)
            return null
        }
        if (!hasRequiredPermissions()) {
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
            return null
        }
        if (!isWifiEnabled()) {
            result.error("wifi_unavailable", "Wi-Fi is unavailable or disabled", null)
            return null
        }
        return (manager ?: return null) to (channel ?: return null)
    }

    private fun startScan(timeoutMs: Long, result: MethodChannel.Result) {
        val ready = requireReady(result) ?: return
        if (!scanning.compareAndSet(false, true)) {
            result.error("wifi_scan_busy", "A Wi-Fi Direct scan is already active", null)
            return
        }
        purgeExpiredCandidates()
        val discovered = LinkedHashMap<String, MutableMap<String, Any?>>()
        val completed = AtomicBoolean(false)
        val (p2p, p2pChannel) = ready
        val request = WifiP2pDnsSdServiceRequest.newInstance()
        activeServiceRequest = request

        p2p.setDnsSdResponseListeners(
            p2pChannel,
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, registrationType, device ->
                if (instanceName != SERVICE_INSTANCE || !registrationType.contains(SERVICE_TYPE)) return@DnsSdServiceResponseListener
                val key = device.deviceAddress ?: return@DnsSdServiceResponseListener
                val entry = discovered.getOrPut(key) { mutableMapOf() }
                entry["device"] = device
            },
            WifiP2pManager.DnsSdTxtRecordListener { _, record, device ->
                val protocol = record[TXT_PROTOCOL]
                val rendezvous = record[TXT_RENDEZVOUS]
                val port = record[TXT_PORT]?.toIntOrNull()
                if (protocol != PROTOCOL || rendezvous == null ||
                    !RENDEZVOUS_PATTERN.matches(rendezvous) || port == null || port !in 1024..65535
                ) {
                    return@DnsSdTxtRecordListener
                }
                val address = device.deviceAddress ?: return@DnsSdTxtRecordListener
                val nativeHandle = UUID.randomUUID().toString()
                val expiresAt = System.currentTimeMillis() + CANDIDATE_TTL_MS
                candidates[nativeHandle] = Candidate(device, port, rendezvous, expiresAt)
                discovered[address] = mutableMapOf(
                    "nativeHandle" to nativeHandle,
                    "rendezvousId" to (NearbyDiscoveryProtocol.rendezvous(
                        record["kind"]?.toIntOrNull() ?: 0, rendezvous,
                    ) ?: return@DnsSdTxtRecordListener),
                    "expiresAtMs" to expiresAt,
                )
            },
        )

        p2p.addServiceRequest(p2pChannel, request, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                p2p.discoverServices(p2pChannel, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        mainHandler.postDelayed({
                            if (!completed.compareAndSet(false, true)) return@postDelayed
                            stopScanInternal()
                            val payload = discovered.values.mapNotNull { raw ->
                                val nativeHandle = raw["nativeHandle"] as? String ?: return@mapNotNull null
                                mapOf(
                                    "nativeHandle" to nativeHandle,
                                    "rendezvousId" to raw["rendezvousId"],
                                    "expiresAtMs" to raw["expiresAtMs"],
                                )
                            }
                            result.success(payload)
                        }, timeoutMs)
                    }

                    override fun onFailure(reason: Int) {
                        if (!completed.compareAndSet(false, true)) return
                        stopScanInternal()
                        postResult { result.error("wifi_scan_failed", "Wi-Fi Direct discovery failed: $reason", null) }
                    }
                })
            }

            override fun onFailure(reason: Int) {
                if (!completed.compareAndSet(false, true)) return
                stopScanInternal()
                postResult { result.error("wifi_scan_failed", "Wi-Fi Direct service request failed: $reason", null) }
            }
        })
    }

    private fun stopScanInternal() {
        scanning.set(false)
        val p2p = manager ?: return
        val p2pChannel = channel ?: return
        val request = activeServiceRequest
        activeServiceRequest = null
        try {
            if (request != null) p2p.removeServiceRequest(p2pChannel, request, null)
        } catch (_: Throwable) {
        }
        try {
            p2p.stopPeerDiscovery(p2pChannel, null)
        } catch (_: Throwable) {
        }
    }

    private fun startAdvertising(rendezvousId: String, result: MethodChannel.Result) {
        val ready = requireReady(result) ?: return
        if (!advertising.compareAndSet(false, true)) {
            result.error("wifi_advertise_busy", "Wi-Fi Direct advertising is already active", null)
            return
        }
        val socket = try {
            ServerSocket(0).apply { reuseAddress = true }
        } catch (_: Throwable) {
            advertising.set(false)
            result.error("wifi_listen_failed", "Unable to open Wi-Fi Direct listener", null)
            return
        }
        serverSocket = socket
        val rendezvous = MessageDigest.getInstance("SHA-256")
            .digest(rendezvousId.toByteArray(Charsets.UTF_8))
            .copyOfRange(0, RENDEZVOUS_DIGEST_BYTES)
            .joinToString(separator = "") { "%02x".format(it) }
        val txt = mapOf(
            TXT_PROTOCOL to PROTOCOL,
            "kind" to NearbyDiscoveryProtocol.kind(rendezvousId).toString(),
            TXT_RENDEZVOUS to rendezvous,
            TXT_PORT to socket.localPort.toString(),
        )
        val info = WifiP2pDnsSdServiceInfo.newInstance(
            SERVICE_INSTANCE,
            SERVICE_TYPE,
            txt,
        )
        localServiceInfo = info
        val (p2p, p2pChannel) = ready
        p2p.addLocalService(p2pChannel, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                startAcceptLoop(socket)
                postResult { result.success(mapOf("active" to true)) }
            }

            override fun onFailure(reason: Int) {
                advertising.set(false)
                localServiceInfo = null
                serverSocket = null
                try { socket.close() } catch (_: Throwable) {}
                postResult { result.error("wifi_advertise_failed", "Wi-Fi Direct local service failed: $reason", null) }
            }
        })
    }

    private fun startAcceptLoop(socket: ServerSocket) {
        ioExecutor.execute {
            while (advertising.get() && serverSocket === socket) {
                val accepted = try {
                    socket.accept()
                } catch (_: Throwable) {
                    break
                }
                val handle = registerLink(accepted)
                if (handle != null) acceptedLinks.offer(handle)
            }
        }
    }

    private fun stopAdvertising() {
        advertising.set(false)
        val info = localServiceInfo
        localServiceInfo = null
        val p2p = manager
        val p2pChannel = channel
        if (p2p != null && p2pChannel != null && info != null) {
            try { p2p.removeLocalService(p2pChannel, info, null) } catch (_: Throwable) {}
        }
        val socket = serverSocket
        serverSocket = null
        try { socket?.close() } catch (_: Throwable) {}
    }

    private fun connect(nativeHandle: String, result: MethodChannel.Result) {
        val ready = requireReady(result) ?: return
        purgeExpiredCandidates()
        val candidate = candidates.remove(nativeHandle)
        if (candidate == null || candidate.expiresAtMs <= System.currentTimeMillis()) {
            result.error("candidate_expired", "Wi-Fi Direct candidate expired", null)
            return
        }
        val config = WifiP2pConfig().apply {
            deviceAddress = candidate.device.deviceAddress
            groupOwnerIntent = 0
        }
        val (p2p, p2pChannel) = ready
        p2p.connect(p2pChannel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                waitForConnectionInfo(candidate, result, System.currentTimeMillis() + CONNECT_TIMEOUT_MS)
            }

            override fun onFailure(reason: Int) {
                postResult { result.error("wifi_connect_failed", "Wi-Fi Direct connect failed: $reason", null) }
            }
        })
    }

    private fun waitForConnectionInfo(
        candidate: Candidate,
        result: MethodChannel.Result,
        deadlineMs: Long,
    ) {
        val p2p = manager ?: run {
            result.error("wifi_connect_failed", "Wi-Fi Direct manager unavailable", null)
            return
        }
        val p2pChannel = channel ?: run {
            result.error("wifi_connect_failed", "Wi-Fi Direct channel unavailable", null)
            return
        }
        p2p.requestConnectionInfo(p2pChannel) { info ->
            if (!info.groupFormed) {
                if (System.currentTimeMillis() >= deadlineMs) {
                    result.error("wifi_connect_timeout", "Wi-Fi Direct group formation timed out", null)
                } else {
                    mainHandler.postDelayed({ waitForConnectionInfo(candidate, result, deadlineMs) }, 250L)
                }
                return@requestConnectionInfo
            }
            if (info.isGroupOwner) {
                result.error(
                    "wifi_direct_role_mismatch",
                    "Local device became group owner; peer should use the incoming link",
                    null,
                )
                return@requestConnectionInfo
            }
            val owner = info.groupOwnerAddress
            if (owner == null) {
                result.error("wifi_connect_failed", "Wi-Fi Direct group owner address unavailable", null)
                return@requestConnectionInfo
            }
            ioExecutor.execute {
                val socket = Socket()
                try {
                    socket.tcpNoDelay = true
                    socket.connect(InetSocketAddress(owner, candidate.port), SOCKET_CONNECT_TIMEOUT_MS.toInt())
                    val linkHandle = registerLink(socket)
                        ?: throw IllegalStateException("Unable to register Wi-Fi Direct link")
                    postResult { result.success(mapOf("linkHandle" to linkHandle)) }
                } catch (_: Throwable) {
                    try { socket.close() } catch (_: Throwable) {}
                    postResult { result.error("wifi_socket_failed", "Wi-Fi Direct TCP connection failed", null) }
                }
            }
        }
    }

    private fun accept(timeoutMs: Long, result: MethodChannel.Result) {
        ioExecutor.execute {
            val handle = try {
                acceptedLinks.poll(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                null
            }
            postResult { result.success(handle?.let { mapOf("linkHandle" to it) }) }
        }
    }

    private fun registerLink(socket: Socket): String? {
        return try {
            socket.tcpNoDelay = true
            socket.soTimeout = 0
            val handle = UUID.randomUUID().toString()
            links[handle] = LinkState(
                socket,
                DataInputStream(BufferedInputStream(socket.getInputStream())),
                DataOutputStream(BufferedOutputStream(socket.getOutputStream())),
            )
            handle
        } catch (_: Throwable) {
            try { socket.close() } catch (_: Throwable) {}
            null
        }
    }

    private fun send(linkHandle: String, bytes: ByteArray, result: MethodChannel.Result) {
        if (bytes.isEmpty() || bytes.size > MAX_FRAME_BYTES) {
            result.error("frame_too_large", "Wi-Fi Direct frame exceeds bounds", null)
            return
        }
        val link = links[linkHandle]
        if (link == null || link.closed.get()) {
            result.error("link_closed", "Wi-Fi Direct link is closed", null)
            return
        }
        ioExecutor.execute {
            try {
                synchronized(link.writeLock) {
                    link.output.writeInt(bytes.size)
                    link.output.write(bytes)
                    link.output.flush()
                }
                postResult { result.success(null) }
            } catch (_: Throwable) {
                closeLink(linkHandle)
                postResult { result.error("link_write_failed", "Wi-Fi Direct write failed", null) }
            }
        }
    }

    private fun receive(linkHandle: String, timeoutMs: Long, result: MethodChannel.Result) {
        val link = links[linkHandle]
        if (link == null || link.closed.get()) {
            result.error("link_closed", "Wi-Fi Direct link is closed", null)
            return
        }
        ioExecutor.execute {
            try {
                link.socket.soTimeout = timeoutMs.toInt().coerceAtLeast(1)
                val length = link.input.readInt()
                if (length <= 0 || length > MAX_FRAME_BYTES) {
                    throw IllegalStateException("Invalid Wi-Fi Direct frame size")
                }
                val bytes = ByteArray(length)
                link.input.readFully(bytes)
                postResult { result.success(bytes) }
            } catch (_: java.net.SocketTimeoutException) {
                postResult { result.error("receive_timeout", "Wi-Fi Direct receive timed out", null) }
            } catch (_: Throwable) {
                closeLink(linkHandle)
                postResult { result.error("link_read_failed", "Wi-Fi Direct read failed", null) }
            } finally {
                try { link.socket.soTimeout = 0 } catch (_: Throwable) {}
            }
        }
    }

    private fun closeLink(handle: String) {
        val link = links.remove(handle) ?: return
        if (!link.closed.compareAndSet(false, true)) return
        try { link.input.close() } catch (_: Throwable) {}
        try { link.output.close() } catch (_: Throwable) {}
        try { link.socket.close() } catch (_: Throwable) {}
    }

    private fun startForegroundMode() {
        val intent = Intent(activity, NearbyForegroundService::class.java).apply {
            putExtra(NearbyForegroundService.EXTRA_MODE, "Wi-Fi Direct")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun purgeExpiredCandidates() {
        val now = System.currentTimeMillis()
        candidates.entries.removeIf { it.value.expiresAtMs <= now }
    }

    private fun postResult(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun boundedTimeout(value: Long?, fallback: Long): Long =
        (value ?: fallback).coerceIn(100L, 60_000L)

    private data class Candidate(
        val device: WifiP2pDevice,
        val port: Int,
        val rendezvous: String,
        val expiresAtMs: Long,
    )

    private data class LinkState(
        val socket: Socket,
        val input: DataInputStream,
        val output: DataOutputStream,
        val writeLock: Any = Any(),
        val closed: AtomicBoolean = AtomicBoolean(false),
    )

    companion object {
        const val CHANNEL = "loom/nearby_wifi_direct_v2"
        private const val REQUEST_PERMISSIONS = 9053
        const val REQUEST_WIFI_SETTINGS = 9054
        private const val SERVICE_INSTANCE = "Loom-v2"
        private const val SERVICE_TYPE = "_loom._tcp"
        private const val PROTOCOL = "loom-nearby-v2"
        private const val TXT_PROTOCOL = "p"
        private const val TXT_RENDEZVOUS = "r"
        private const val TXT_PORT = "port"
        private const val RENDEZVOUS_DIGEST_BYTES = 8
        private val RENDEZVOUS_PATTERN = Regex("^[0-9a-f]{16}$")
        private const val CANDIDATE_TTL_MS = 30_000L
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val SOCKET_CONNECT_TIMEOUT_MS = 10_000L
        private const val MAX_FRAME_BYTES = 320 * 1024
    }
}
