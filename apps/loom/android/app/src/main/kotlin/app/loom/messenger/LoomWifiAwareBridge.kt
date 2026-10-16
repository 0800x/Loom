package app.loom.messenger

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.SubscribeDiscoverySession
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android Wi-Fi Aware (NAN) bearer for Loom Architecture v2.
 *
 * Discovery publishes only a rotating rendezvous digest and an ephemeral NDP
 * passphrase. PeerHandle, IPv6 addresses and network objects stay native. The
 * resulting TCP stream is a raw bearer; Loom's peer authentication/encryption
 * remains mandatory above it before DTN data is trusted.
 *
 * Data-path setup follows the Android 10+ client/server flow: subscriber sends
 * an Aware L2 request message, publisher requests an NDP with its ServerSocket
 * port, acknowledges the request, then subscriber requests the matching NDP and
 * opens a socket using WifiAwareNetworkInfo's peer IPv6/port.
 */
class LoomWifiAwareBridge(
    private val activity: Activity,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()
    private val awareManager = activity.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
    private val connectivityManager =
        activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val candidates = ConcurrentHashMap<String, Candidate>()
    private val pendingConnects = ConcurrentHashMap<Int, PendingConnect>()
    private val links = ConcurrentHashMap<String, LinkState>()
    private val acceptedLinks = LinkedBlockingQueue<String>()
    private val callbacks = CopyOnWriteArraySet<ConnectivityManager.NetworkCallback>()
    private val scanning = AtomicBoolean(false)
    private val advertising = AtomicBoolean(false)
    private val secureRandom = SecureRandom()

    @Volatile
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile
    private var pendingReadyResult: MethodChannel.Result? = null

    @Volatile
    private var scanAwareSession: WifiAwareSession? = null

    @Volatile
    private var subscribeSession: SubscribeDiscoverySession? = null

    @Volatile
    private var advertiseAwareSession: WifiAwareSession? = null

    @Volatile
    private var publishSession: PublishDiscoverySession? = null

    @Volatile
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var advertisePassphrase: String? = null

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
                    result.error("invalid_candidate", "Missing Wi-Fi Aware candidate handle", null)
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
                    result.error("invalid_send", "Missing Wi-Fi Aware link or frame", null)
                } else {
                    send(linkHandle, bytes, result)
                }
                return true
            }
            "receive" -> {
                val linkHandle = call.argument<String>("linkHandle")
                val timeoutMs = boundedTimeout(call.argument<Number>("timeoutMs")?.toLong(), 30_000L)
                if (linkHandle.isNullOrBlank()) {
                    result.error("invalid_receive", "Missing Wi-Fi Aware link handle", null)
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
            postResult {
                pending.success(hasRequiredPermissions() && isAwareAvailable())
            }
        }
        return true
    }

    fun shutdown() {
        stopScanSession()
        stopAdvertising()
        pendingConnects.values.forEach { pending ->
            if (pending.completed.compareAndSet(false, true)) {
                postResult {
                    pending.result.error("activity_closed", "Wi-Fi Aware connection interrupted", null)
                }
            }
        }
        pendingConnects.clear()
        callbacks.toList().forEach(::unregisterCallback)
        links.keys.toList().forEach(::closeLink)
        candidates.clear()
        ioExecutor.shutdownNow()
        pendingPermissionResult?.let { pending ->
            postResult {
                pending.error("activity_closed", "Wi-Fi Aware permission request interrupted", null)
            }
        }
        pendingPermissionResult = null
        pendingReadyResult?.let { pending ->
            postResult {
                pending.error("activity_closed", "Wi-Fi settings request interrupted", null)
            }
        }
        pendingReadyResult = null
    }

    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) return false
        return awareManager != null
    }

    private fun isAwareAvailable(): Boolean = try {
        awareManager?.isAvailable == true
    } catch (_: SecurityException) {
        false
    }

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
            result.error("wifi_aware_unsupported", "Wi-Fi Aware is not supported", null)
            return
        }
        if (!hasRequiredPermissions()) {
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
            return
        }
        if (isAwareAvailable()) {
            result.success(true)
            return
        }
        if (pendingReadyResult != null) {
            result.error("wifi_settings_busy", "A Wi-Fi settings request is already active", null)
            return
        }
        pendingReadyResult = result
        try {
            activity.startActivityForResult(
                Intent(Settings.Panel.ACTION_WIFI),
                REQUEST_WIFI_SETTINGS,
            )
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

    private fun requireReady(result: MethodChannel.Result): WifiAwareManager? {
        if (!isSupported()) {
            result.error("wifi_aware_unsupported", "Wi-Fi Aware is not supported", null)
            return null
        }
        if (!hasRequiredPermissions()) {
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
            return null
        }
        if (!isAwareAvailable()) {
            result.error("wifi_unavailable", "Wi-Fi Aware is unavailable or Wi-Fi is disabled", null)
            return null
        }
        return awareManager
    }

    private fun startScan(timeoutMs: Long, result: MethodChannel.Result) {
        val aware = requireReady(result) ?: return
        if (!scanning.compareAndSet(false, true)) {
            result.error("aware_scan_busy", "A Wi-Fi Aware scan is already active", null)
            return
        }
        stopScanSession(closeFlag = false)
        candidates.clear()
        val discovered = LinkedHashMap<String, Map<String, Any?>>()
        val completed = AtomicBoolean(false)

        try {
            aware.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    scanAwareSession = session
                    val config = SubscribeConfig.Builder()
                        .setServiceName(SERVICE_NAME)
                        .setSubscribeType(SubscribeConfig.SUBSCRIBE_TYPE_PASSIVE)
                        .build()
                    session.subscribe(config, object : DiscoverySessionCallback() {
                        override fun onSubscribeStarted(session: SubscribeDiscoverySession) {
                            subscribeSession = session
                        }

                        override fun onServiceDiscovered(
                            peerHandle: PeerHandle,
                            serviceSpecificInfo: ByteArray,
                            matchFilter: MutableList<ByteArray>,
                        ) {
                            val parsed = parseServiceInfo(serviceSpecificInfo) ?: return
                            val nativeHandle = UUID.randomUUID().toString()
                            val expiresAt = System.currentTimeMillis() + CANDIDATE_TTL_MS
                            candidates[nativeHandle] = Candidate(
                                peerHandle,
                                parsed.second,
                                expiresAt,
                            )
                            discovered[nativeHandle] = mapOf(
                                "nativeHandle" to nativeHandle,
                                "rendezvousId" to parsed.first,
                                "expiresAtMs" to expiresAt,
                            )
                        }

                        override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                            if (!message.contentEquals(CONNECT_ACK)) return
                            val pending = pendingConnects[peerHandle.hashCode()] ?: return
                            requestSubscriberNetwork(pending)
                        }

                        override fun onSessionConfigFailed() {
                            if (!completed.compareAndSet(false, true)) return
                            scanning.set(false)
                            postResult {
                                result.error("aware_scan_failed", "Wi-Fi Aware subscribe configuration failed", null)
                            }
                        }
                    }, mainHandler)

                    mainHandler.postDelayed({
                        if (!completed.compareAndSet(false, true)) return@postDelayed
                        scanning.set(false)
                        result.success(discovered.values.toList())
                    }, timeoutMs)
                }

                override fun onAttachFailed() {
                    if (!completed.compareAndSet(false, true)) return
                    scanning.set(false)
                    postResult { result.error("aware_attach_failed", "Wi-Fi Aware attach failed", null) }
                }
            }, mainHandler)
        } catch (_: SecurityException) {
            scanning.set(false)
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
        } catch (_: Throwable) {
            scanning.set(false)
            result.error("aware_scan_failed", "Wi-Fi Aware scan could not start", null)
        }
    }

    private fun stopScanSession(closeFlag: Boolean = true) {
        if (closeFlag) scanning.set(false)
        try { subscribeSession?.close() } catch (_: Throwable) {}
        subscribeSession = null
        try { scanAwareSession?.close() } catch (_: Throwable) {}
        scanAwareSession = null
    }

    private fun startAdvertising(rendezvousId: String, result: MethodChannel.Result) {
        val aware = requireReady(result) ?: return
        if (!advertising.compareAndSet(false, true)) {
            result.error("aware_advertise_busy", "Wi-Fi Aware advertising is already active", null)
            return
        }
        val server = try {
            ServerSocket(0).apply { reuseAddress = true }
        } catch (_: Throwable) {
            advertising.set(false)
            result.error("aware_listen_failed", "Unable to open Wi-Fi Aware listener", null)
            return
        }
        serverSocket = server
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(rendezvousId.toByteArray(Charsets.UTF_8))
            .copyOfRange(0, RENDEZVOUS_DIGEST_BYTES)
            .joinToString(separator = "") { "%02x".format(it) }
        val passphraseBytes = ByteArray(24).also(secureRandom::nextBytes)
        val passphrase = Base64.encodeToString(
            passphraseBytes,
            Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE,
        )
        passphraseBytes.fill(0)
        advertisePassphrase = passphrase
        val info = "v2|$digest|$passphrase|${NearbyDiscoveryProtocol.kind(rendezvousId)}".toByteArray(Charsets.US_ASCII)

        try {
            aware.attach(object : AttachCallback() {
                override fun onAttached(session: WifiAwareSession) {
                    advertiseAwareSession = session
                    val config = PublishConfig.Builder()
                        .setServiceName(SERVICE_NAME)
                        .setServiceSpecificInfo(info)
                        .setPublishType(PublishConfig.PUBLISH_TYPE_UNSOLICITED)
                        .build()
                    session.publish(config, object : DiscoverySessionCallback() {
                        override fun onPublishStarted(session: PublishDiscoverySession) {
                            publishSession = session
                            startAcceptLoop(server)
                            postResult { result.success(mapOf("active" to true)) }
                        }

                        override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray) {
                            if (!message.contentEquals(CONNECT_REQUEST)) return
                            requestPublisherNetwork(peerHandle)
                        }

                        override fun onSessionConfigFailed() {
                            stopAdvertising()
                            postResult {
                                result.error("aware_advertise_failed", "Wi-Fi Aware publish configuration failed", null)
                            }
                        }
                    }, mainHandler)
                }

                override fun onAttachFailed() {
                    stopAdvertising()
                    postResult { result.error("aware_attach_failed", "Wi-Fi Aware attach failed", null) }
                }
            }, mainHandler)
        } catch (_: SecurityException) {
            stopAdvertising()
            result.error("wifi_permission_required", "Nearby Wi-Fi permission is required", null)
        } catch (_: Throwable) {
            stopAdvertising()
            result.error("aware_advertise_failed", "Wi-Fi Aware advertising could not start", null)
        }
    }

    private fun requestPublisherNetwork(peerHandle: PeerHandle) {
        val session = publishSession ?: return
        val passphrase = advertisePassphrase ?: return
        val port = serverSocket?.localPort ?: return
        val specifier = try {
            WifiAwareNetworkSpecifier.Builder(session, peerHandle)
                .setPskPassphrase(passphrase)
                .setPort(port)
                .build()
        } catch (_: Throwable) {
            return
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) {
                unregisterCallback(this)
            }
        }
        callbacks.add(callback)
        try {
            connectivityManager.requestNetwork(request, callback, NETWORK_TIMEOUT_MS.toInt())
            session.sendMessage(peerHandle, MESSAGE_ID_ACK, CONNECT_ACK)
        } catch (_: Throwable) {
            unregisterCallback(callback)
        }
    }

    private fun connect(nativeHandle: String, result: MethodChannel.Result) {
        requireReady(result) ?: return
        purgeExpiredCandidates()
        val candidate = candidates.remove(nativeHandle)
        val session = subscribeSession
        if (candidate == null || candidate.expiresAtMs <= System.currentTimeMillis() || session == null) {
            result.error("candidate_expired", "Wi-Fi Aware candidate expired", null)
            return
        }
        val key = candidate.peerHandle.hashCode()
        if (pendingConnects.containsKey(key)) {
            result.error("aware_connect_busy", "Connection to this Wi-Fi Aware peer is already pending", null)
            return
        }
        val pending = PendingConnect(candidate, session, result)
        pendingConnects[key] = pending
        mainHandler.postDelayed({
            if (pending.completed.compareAndSet(false, true)) {
                pendingConnects.remove(key)
                result.error("aware_connect_timeout", "Wi-Fi Aware connection timed out", null)
            }
        }, NETWORK_TIMEOUT_MS)
        try {
            session.sendMessage(candidate.peerHandle, MESSAGE_ID_REQUEST, CONNECT_REQUEST)
        } catch (_: Throwable) {
            if (pending.completed.compareAndSet(false, true)) {
                pendingConnects.remove(key)
                result.error("aware_message_failed", "Wi-Fi Aware connection request failed", null)
            }
        }
    }

    private fun requestSubscriberNetwork(pending: PendingConnect) {
        if (pending.networkRequested.compareAndSet(false, true).not()) return
        val candidate = pending.candidate
        val specifier = try {
            WifiAwareNetworkSpecifier.Builder(pending.session, candidate.peerHandle)
                .setPskPassphrase(candidate.passphrase)
                .build()
        } catch (_: Throwable) {
            failPending(pending, "aware_specifier_failed", "Unable to build Wi-Fi Aware data path")
            return
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            private val socketStarted = AtomicBoolean(false)

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (!socketStarted.compareAndSet(false, true)) return
                val info = capabilities.transportInfo as? WifiAwareNetworkInfo
                val peerIpv6 = info?.peerIpv6Addr
                val port = info?.port ?: 0
                if (peerIpv6 == null || port !in 1..65535) {
                    socketStarted.set(false)
                    return
                }
                ioExecutor.execute {
                    try {
                        val socket = network.socketFactory.createSocket(peerIpv6, port)
                        val linkHandle = registerLink(socket)
                            ?: throw IllegalStateException("Unable to register Wi-Fi Aware link")
                        if (pending.completed.compareAndSet(false, true)) {
                            pendingConnects.remove(candidate.peerHandle.hashCode())
                            postResult { pending.result.success(mapOf("linkHandle" to linkHandle)) }
                        } else {
                            closeLink(linkHandle)
                        }
                    } catch (_: Throwable) {
                        failPending(pending, "aware_socket_failed", "Wi-Fi Aware socket connection failed")
                    }
                }
            }

            override fun onUnavailable() {
                failPending(pending, "aware_network_unavailable", "Wi-Fi Aware data path unavailable")
                unregisterCallback(this)
            }

            override fun onLost(network: Network) {
                unregisterCallback(this)
            }
        }
        callbacks.add(callback)
        try {
            connectivityManager.requestNetwork(request, callback, NETWORK_TIMEOUT_MS.toInt())
        } catch (_: Throwable) {
            unregisterCallback(callback)
            failPending(pending, "aware_network_failed", "Wi-Fi Aware data path request failed")
        }
    }

    private fun failPending(pending: PendingConnect, code: String, message: String) {
        if (!pending.completed.compareAndSet(false, true)) return
        pendingConnects.remove(pending.candidate.peerHandle.hashCode())
        postResult { pending.result.error(code, message, null) }
    }

    private fun startAcceptLoop(server: ServerSocket) {
        ioExecutor.execute {
            while (advertising.get() && serverSocket === server) {
                val socket = try {
                    server.accept()
                } catch (_: Throwable) {
                    break
                }
                val handle = registerLink(socket)
                if (handle != null) acceptedLinks.offer(handle)
            }
        }
    }

    private fun stopAdvertising() {
        advertising.set(false)
        advertisePassphrase = null
        try { publishSession?.close() } catch (_: Throwable) {}
        publishSession = null
        try { advertiseAwareSession?.close() } catch (_: Throwable) {}
        advertiseAwareSession = null
        val server = serverSocket
        serverSocket = null
        try { server?.close() } catch (_: Throwable) {}
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
            result.error("frame_too_large", "Wi-Fi Aware frame exceeds bounds", null)
            return
        }
        val link = links[linkHandle]
        if (link == null || link.closed.get()) {
            result.error("link_closed", "Wi-Fi Aware link is closed", null)
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
                postResult { result.error("link_write_failed", "Wi-Fi Aware write failed", null) }
            }
        }
    }

    private fun receive(linkHandle: String, timeoutMs: Long, result: MethodChannel.Result) {
        val link = links[linkHandle]
        if (link == null || link.closed.get()) {
            result.error("link_closed", "Wi-Fi Aware link is closed", null)
            return
        }
        ioExecutor.execute {
            try {
                link.socket.soTimeout = timeoutMs.toInt().coerceAtLeast(1)
                val length = link.input.readInt()
                if (length <= 0 || length > MAX_FRAME_BYTES) {
                    throw IllegalStateException("Invalid Wi-Fi Aware frame size")
                }
                val bytes = ByteArray(length)
                link.input.readFully(bytes)
                postResult { result.success(bytes) }
            } catch (_: java.net.SocketTimeoutException) {
                postResult { result.error("receive_timeout", "Wi-Fi Aware receive timed out", null) }
            } catch (_: Throwable) {
                closeLink(linkHandle)
                postResult { result.error("link_read_failed", "Wi-Fi Aware read failed", null) }
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

    private fun unregisterCallback(callback: ConnectivityManager.NetworkCallback) {
        if (!callbacks.remove(callback)) return
        try { connectivityManager.unregisterNetworkCallback(callback) } catch (_: Throwable) {}
    }

    private fun parseServiceInfo(bytes: ByteArray): Pair<String, String>? {
        if (bytes.isEmpty() || bytes.size > 256) return null
        val value = try { bytes.toString(Charsets.US_ASCII) } catch (_: Throwable) { return null }
        val parts = value.split('|')
        if (parts.size !in 3..4 || parts[0] != "v2") return null
        val digest = parts[1]
        val passphrase = parts[2]
        if (!RENDEZVOUS_PATTERN.matches(digest) ||
            passphrase.length !in 8..63 ||
            !PASSPHRASE_PATTERN.matches(passphrase)
        ) return null
        val kind = if (parts.size == 4) parts[3].toIntOrNull() ?: return null else 0
        return (NearbyDiscoveryProtocol.rendezvous(kind, digest) ?: return null) to passphrase
    }

    private fun purgeExpiredCandidates() {
        val now = System.currentTimeMillis()
        candidates.entries.removeIf { it.value.expiresAtMs <= now }
    }

    private fun startForegroundMode() {
        val intent = Intent(activity, NearbyForegroundService::class.java).apply {
            putExtra(NearbyForegroundService.EXTRA_MODE, "Wi-Fi Aware")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun postResult(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun boundedTimeout(value: Long?, fallback: Long): Long =
        (value ?: fallback).coerceIn(100L, 60_000L)

    private data class Candidate(
        val peerHandle: PeerHandle,
        val passphrase: String,
        val expiresAtMs: Long,
    )

    private class PendingConnect(
        val candidate: Candidate,
        val session: SubscribeDiscoverySession,
        val result: MethodChannel.Result,
        val completed: AtomicBoolean = AtomicBoolean(false),
        val networkRequested: AtomicBoolean = AtomicBoolean(false),
    )

    private data class LinkState(
        val socket: Socket,
        val input: DataInputStream,
        val output: DataOutputStream,
        val writeLock: Any = Any(),
        val closed: AtomicBoolean = AtomicBoolean(false),
    )

    companion object {
        const val CHANNEL = "loom/nearby_wifi_aware_v2"
        private const val REQUEST_PERMISSIONS = 9054
        const val REQUEST_WIFI_SETTINGS = 9056
        private const val SERVICE_NAME = "loom-v2"
        private const val RENDEZVOUS_DIGEST_BYTES = 8
        private val RENDEZVOUS_PATTERN = Regex("^[0-9a-f]{16}$")
        private val PASSPHRASE_PATTERN = Regex("^[A-Za-z0-9_-]{8,63}$")
        private const val CANDIDATE_TTL_MS = 30_000L
        private const val NETWORK_TIMEOUT_MS = 20_000L
        private const val MAX_FRAME_BYTES = 320 * 1024
        private const val MESSAGE_ID_REQUEST = 41
        private const val MESSAGE_ID_ACK = 42
        private val CONNECT_REQUEST = "loom-connect-v2".toByteArray(Charsets.US_ASCII)
        private val CONNECT_ACK = "loom-accept-v2".toByteArray(Charsets.US_ASCII)
    }
}
