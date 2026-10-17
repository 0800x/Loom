package app.loom.messenger

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android BLE transport bridge for Loom Architecture v2.
 *
 * Discovery uses a custom 128-bit service-data UUID containing only a dynamic
 * L2CAP PSM and a four-byte digest of the caller-supplied rotating rendezvous
 * value. No username, Loom address, account/device key, Home Node, or MAC
 * address is returned to Dart. BluetoothDevice/address objects remain native
 * and are referenced by short-lived random handles.
 *
 * The L2CAP CoC is intentionally opened with the insecure platform API because
 * Loom authenticates and encrypts the peer link above this raw bearer. The
 * raw link must never be treated as identity or as an authenticated channel.
 */
class LoomBleBridge(
    private val activity: Activity,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()
    private val candidates = ConcurrentHashMap<String, Candidate>()
    private val links = ConcurrentHashMap<String, LinkState>()
    private val acceptedLinks = LinkedBlockingQueue<String>()
    private val scanLock = Any()

    @Volatile
    private var pendingPermissionResult: MethodChannel.Result? = null

    @Volatile
    private var pendingEnableResult: MethodChannel.Result? = null

    @Volatile
    private var activeScan: ActiveScan? = null

    @Volatile
    private var serverSocket: BluetoothServerSocket? = null

    @Volatile
    private var advertiseCallback: AdvertiseCallback? = null

    private val advertising = AtomicBoolean(false)

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
                    result.error("invalid_candidate", "Missing BLE candidate handle", null)
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
                    result.error("invalid_send", "Missing BLE link or frame", null)
                } else {
                    send(linkHandle, bytes, result)
                }
                return true
            }
            "receive" -> {
                val linkHandle = call.argument<String>("linkHandle")
                val timeoutMs = boundedTimeout(call.argument<Number>("timeoutMs")?.toLong(), 30_000L)
                if (linkHandle.isNullOrBlank()) {
                    result.error("invalid_receive", "Missing BLE link handle", null)
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

    fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQUEST_ENABLE) return false
        val pending = pendingEnableResult
        pendingEnableResult = null
        if (pending != null) {
            val enabled = try {
                hasRequiredPermissions() && bluetoothAdapter()?.isEnabled == true
            } catch (_: SecurityException) {
                false
            }
            postResult { pending.success(enabled) }
        }
        return true
    }

    fun shutdown() {
        synchronized(scanLock) {
            activeScan?.let { scan ->
                try {
                    if (hasRequiredPermissions()) {
                        bluetoothAdapter()?.bluetoothLeScanner?.stopScan(scan.callback)
                    }
                } catch (_: Throwable) {
                }
            }
            activeScan = null
        }
        stopAdvertising()
        links.keys.toList().forEach(::closeLink)
        candidates.clear()
        ioExecutor.shutdownNow()
        pendingPermissionResult?.let { pending ->
            postResult {
                pending.error(
                    "activity_closed",
                    "BLE permission request was interrupted",
                    null,
                )
            }
        }
        pendingPermissionResult = null
        pendingEnableResult?.let { pending ->
            postResult {
                pending.error(
                    "activity_closed",
                    "Bluetooth enable request was interrupted",
                    null,
                )
            }
        }
        pendingEnableResult = null
    }

    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return false
        }
        // Do not touch permission-gated adapter state here on Android 12+.
        // Real operations go through requireReady(), which checks permissions
        // and adapter state before scanner/advertiser/connect APIs are accessed.
        return bluetoothAdapter() != null
    }

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun requestPermissions(result: MethodChannel.Result) {
        if (hasRequiredPermissions()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_busy", "A BLE permission request is already active", null)
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
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("ble_l2cap_unsupported", "BLE L2CAP requires Android 10 or newer", null)
            return
        }
        if (!hasRequiredPermissions()) {
            result.error("ble_permission_required", "Nearby-device permission is required", null)
            return
        }
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            result.error("bluetooth_unavailable", "Bluetooth is unavailable on this device", null)
            return
        }
        val enabled = try {
            adapter.isEnabled
        } catch (_: SecurityException) {
            result.error("ble_permission_required", "Nearby-device permission is required", null)
            return
        }
        if (enabled) {
            result.success(true)
            return
        }
        if (pendingEnableResult != null) {
            result.error("bluetooth_enable_busy", "A Bluetooth enable request is already active", null)
            return
        }
        pendingEnableResult = result
        try {
            activity.startActivityForResult(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                REQUEST_ENABLE,
            )
        } catch (error: Throwable) {
            pendingEnableResult = null
            result.error(
                "bluetooth_enable_unavailable",
                "Unable to open Android Bluetooth enable flow",
                null,
            )
        }
    }

    private fun requiredPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasRequiredPermissions(): Boolean = requiredPermissions().all {
        activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun requireReady(result: MethodChannel.Result): BluetoothAdapter? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("ble_l2cap_unsupported", "BLE L2CAP requires Android 10 or newer", null)
            return null
        }
        if (!hasRequiredPermissions()) {
            result.error("ble_permission_required", "Nearby-device permission is required", null)
            return null
        }
        val adapter = bluetoothAdapter()
        try {
            if (adapter == null || !adapter.isEnabled) {
                result.error("bluetooth_unavailable", "Bluetooth is unavailable or disabled", null)
                return null
            }
        } catch (_: SecurityException) {
            result.error("ble_permission_required", "Nearby-device permission is required", null)
            return null
        }
        return adapter
    }

    private fun startScan(timeoutMs: Long, result: MethodChannel.Result) {
        val adapter = requireReady(result) ?: return
        val scanner = try {
            adapter.bluetoothLeScanner
        } catch (_: SecurityException) {
            result.error("ble_permission_required", "BLE scan permission is required", null)
            return
        }
        if (scanner == null) {
            result.error("ble_scan_unavailable", "BLE scanner is unavailable", null)
            return
        }

        synchronized(scanLock) {
            if (activeScan != null) {
                result.error("ble_scan_busy", "A BLE scan is already active", null)
                return
            }

            purgeExpiredCandidates()
            val discovered = LinkedHashMap<String, Map<String, Any?>>()
            val completed = AtomicBoolean(false)
            lateinit var callback: ScanCallback
            callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                    recordScanResult(scanResult, discovered)
                }

                override fun onBatchScanResults(results: MutableList<ScanResult>) {
                    results.forEach { recordScanResult(it, discovered) }
                }

                override fun onScanFailed(errorCode: Int) {
                    if (!completed.compareAndSet(false, true)) return
                    synchronized(scanLock) { activeScan = null }
                    postResult {
                        result.error("ble_scan_failed", "BLE scan failed with code $errorCode", null)
                    }
                }
            }

            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
                .build()
            activeScan = ActiveScan(callback, completed)
            try {
                scanner.startScan(null, settings, callback)
            } catch (_: SecurityException) {
                activeScan = null
                result.error("ble_permission_required", "BLE scan permission is required", null)
                return
            } catch (_: Throwable) {
                activeScan = null
                result.error("ble_scan_failed", "BLE scan could not start", null)
                return
            }

            mainHandler.postDelayed({
                if (!completed.compareAndSet(false, true)) return@postDelayed
                try {
                    scanner.stopScan(callback)
                } catch (_: Throwable) {
                }
                synchronized(scanLock) { activeScan = null }
                result.success(discovered.values.toList())
            }, timeoutMs)
        }
    }

    private fun recordScanResult(
        scanResult: ScanResult,
        discovered: LinkedHashMap<String, Map<String, Any?>>,
    ) {
        val data = scanResult.scanRecord?.getServiceData(SERVICE_UUID) ?: return
        if (data.size != SERVICE_DATA_BYTES) return
        val buffer = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val packedPsm = buffer.int
        val psm = packedPsm and 0xffff
        val serviceKind = packedPsm ushr 16
        if (psm == 0) return
        val tokenBytes = ByteArray(RENDEZVOUS_TOKEN_BYTES)
        buffer.get(tokenBytes)
        val token = tokenBytes.joinToString(separator = "") { "%02x".format(it) }
        val key = "${scanResult.device.address}:$psm"
        if (discovered.containsKey(key)) return

        val nativeHandle = UUID.randomUUID().toString()
        val expiresAt = System.currentTimeMillis() + CANDIDATE_TTL_MS
        candidates[nativeHandle] = Candidate(scanResult.device, psm, expiresAt)
        discovered[key] = mapOf(
            "nativeHandle" to nativeHandle,
            "rendezvousId" to (NearbyDiscoveryProtocol.rendezvous(serviceKind, token) ?: return),
            "signalStrength" to scanResult.rssi,
            "expiresAtMs" to expiresAt,
        )
    }

    private fun startAdvertising(rendezvousId: String, result: MethodChannel.Result) {
        val adapter = requireReady(result) ?: return
        val advertiser = try {
            adapter.bluetoothLeAdvertiser
        } catch (_: SecurityException) {
            result.error("ble_permission_required", "BLE advertise permission is required", null)
            return
        }
        if (advertiser == null) {
            result.error("ble_advertise_unavailable", "BLE advertising is unavailable", null)
            return
        }
        if (!advertising.compareAndSet(false, true)) {
            result.error("ble_advertise_busy", "BLE advertising is already active", null)
            return
        }

        val localServer = try {
            adapter.listenUsingInsecureL2capChannel()
        } catch (_: SecurityException) {
            advertising.set(false)
            result.error("ble_permission_required", "BLE connect permission is required", null)
            return
        } catch (_: Throwable) {
            advertising.set(false)
            result.error("ble_l2cap_listen_failed", "Unable to open BLE L2CAP listener", null)
            return
        }
        serverSocket = localServer
        val psm = localServer.psm
        val token = MessageDigest.getInstance("SHA-256")
            .digest(rendezvousId.toByteArray(Charsets.UTF_8))
            .copyOfRange(0, RENDEZVOUS_TOKEN_BYTES)
        val serviceData = ByteBuffer.allocate(SERVICE_DATA_BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(NearbyDiscoveryProtocol.packedPsm(psm, rendezvousId))
            .put(token)
            .array()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(SERVICE_UUID, serviceData)
            .build()

        lateinit var callback: AdvertiseCallback
        callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                advertiseCallback = callback
                startAcceptLoop(localServer)
                postResult { result.success(mapOf("active" to true)) }
            }

            override fun onStartFailure(errorCode: Int) {
                advertising.set(false)
                advertiseCallback = null
                serverSocket = null
                try {
                    localServer.close()
                } catch (_: Throwable) {
                }
                postResult {
                    result.error(
                        "ble_advertise_failed",
                        "BLE advertising failed with code $errorCode",
                        null,
                    )
                }
            }
        }

        try {
            advertiser.startAdvertising(settings, data, callback)
        } catch (_: SecurityException) {
            advertising.set(false)
            serverSocket = null
            try {
                localServer.close()
            } catch (_: Throwable) {
            }
            result.error("ble_permission_required", "BLE advertise permission is required", null)
        } catch (_: Throwable) {
            advertising.set(false)
            serverSocket = null
            try {
                localServer.close()
            } catch (_: Throwable) {
            }
            result.error("ble_advertise_failed", "BLE advertising could not start", null)
        }
    }

    private fun startAcceptLoop(localServer: BluetoothServerSocket) {
        ioExecutor.execute {
            while (advertising.get() && serverSocket === localServer) {
                val socket = try {
                    localServer.accept()
                } catch (_: IOException) {
                    break
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
        val callback = advertiseCallback
        advertiseCallback = null
        try {
            if (callback != null && hasRequiredPermissions()) {
                bluetoothAdapter()?.bluetoothLeAdvertiser?.stopAdvertising(callback)
            }
        } catch (_: Throwable) {
        }
        val server = serverSocket
        serverSocket = null
        try {
            server?.close()
        } catch (_: Throwable) {
        }
    }

    private fun connect(nativeHandle: String, result: MethodChannel.Result) {
        if (requireReady(result) == null) return
        purgeExpiredCandidates()
        val candidate = candidates.remove(nativeHandle)
        if (candidate == null || candidate.expiresAtMs <= System.currentTimeMillis()) {
            result.error("ble_candidate_expired", "BLE candidate is missing or expired", null)
            return
        }

        ioExecutor.execute {
            val socket = try {
                candidate.device.createInsecureL2capChannel(candidate.psm).also { it.connect() }
            } catch (_: SecurityException) {
                postResult { result.error("ble_permission_required", "BLE connect permission is required", null) }
                return@execute
            } catch (_: Throwable) {
                postResult { result.error("ble_connect_failed", "Unable to establish BLE L2CAP link", null) }
                return@execute
            }
            val handle = registerLink(socket)
            if (handle == null) {
                try {
                    socket.close()
                } catch (_: Throwable) {
                }
                postResult { result.error("ble_connect_failed", "Unable to initialize BLE link", null) }
            } else {
                postResult { result.success(mapOf("linkHandle" to handle)) }
            }
        }
    }

    private fun accept(timeoutMs: Long, result: MethodChannel.Result) {
        ioExecutor.execute {
            val handle = try {
                acceptedLinks.poll(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }
            postResult {
                if (handle == null) result.success(null)
                else result.success(mapOf("linkHandle" to handle))
            }
        }
    }

    private fun registerLink(socket: BluetoothSocket): String? {
        return try {
            val handle = UUID.randomUUID().toString()
            val state = LinkState(socket)
            links[handle] = state
            ioExecutor.execute { readLoop(handle, state) }
            handle
        } catch (_: Throwable) {
            null
        }
    }

    private fun readLoop(handle: String, state: LinkState) {
        try {
            while (!state.closed.get()) {
                val length = state.input.readInt()
                if (length <= 0 || length > MAX_FRAME_BYTES) {
                    throw IOException("Invalid BLE frame length")
                }
                val frame = ByteArray(length)
                state.input.readFully(frame)
                if (!state.incoming.offer(frame, INCOMING_QUEUE_OFFER_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    throw IOException("BLE receive queue is full")
                }
            }
        } catch (_: Throwable) {
            closeLink(handle)
        }
    }

    private fun send(linkHandle: String, bytes: ByteArray, result: MethodChannel.Result) {
        if (bytes.isEmpty() || bytes.size > MAX_FRAME_BYTES) {
            result.error("ble_frame_too_large", "BLE frame exceeds Loom bounds", null)
            return
        }
        val state = links[linkHandle]
        if (state == null || state.closed.get()) {
            result.error("ble_link_closed", "BLE link is not available", null)
            return
        }
        ioExecutor.execute {
            try {
                synchronized(state.writeLock) {
                    state.output.writeInt(bytes.size)
                    state.output.write(bytes)
                    state.output.flush()
                }
                postResult { result.success(null) }
            } catch (_: Throwable) {
                closeLink(linkHandle)
                postResult { result.error("ble_send_failed", "BLE frame send failed", null) }
            }
        }
    }

    private fun receive(linkHandle: String, timeoutMs: Long, result: MethodChannel.Result) {
        val state = links[linkHandle]
        if (state == null) {
            result.error("ble_link_closed", "BLE link is not available", null)
            return
        }
        ioExecutor.execute {
            val frame = try {
                state.incoming.poll(timeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }
            postResult {
                when {
                    frame != null -> result.success(frame)
                    state.closed.get() -> result.error("ble_link_closed", "BLE link closed", null)
                    else -> result.success(null)
                }
            }
        }
    }

    private fun closeLink(linkHandle: String) {
        val state = links.remove(linkHandle) ?: return
        state.close()
    }

    private fun purgeExpiredCandidates() {
        val now = System.currentTimeMillis()
        for ((handle, candidate) in candidates) {
            if (candidate.expiresAtMs <= now) {
                candidates.remove(handle, candidate)
            }
        }
    }

    private fun startForegroundMode() {
        val intent = Intent(activity, NearbyForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun postResult(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun boundedTimeout(value: Long?, fallback: Long): Long {
        val timeout = value ?: fallback
        return timeout.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
    }

    private data class Candidate(
        val device: BluetoothDevice,
        val psm: Int,
        val expiresAtMs: Long,
    )

    private data class ActiveScan(
        val callback: ScanCallback,
        val completed: AtomicBoolean,
    )

    private class LinkState(socket: BluetoothSocket) {
        val closed = AtomicBoolean(false)
        val incoming = ArrayBlockingQueue<ByteArray>(MAX_QUEUED_FRAMES)
        val input = DataInputStream(BufferedInputStream(socket.inputStream))
        val output = DataOutputStream(BufferedOutputStream(socket.outputStream))
        val writeLock = Any()
        private val socketRef = socket

        fun close() {
            if (!closed.compareAndSet(false, true)) return
            try {
                socketRef.close()
            } catch (_: Throwable) {
            }
        }
    }

    companion object {
        const val CHANNEL = "loom/nearby_ble"
        const val REQUEST_PERMISSIONS = 9142
        const val REQUEST_ENABLE = 9143
        private const val MAX_FRAME_BYTES = 320 * 1024
        private const val MAX_QUEUED_FRAMES = 16
        private const val CANDIDATE_TTL_MS = 120_000L
        private const val MIN_TIMEOUT_MS = 100L
        private const val MAX_TIMEOUT_MS = 60_000L
        private const val INCOMING_QUEUE_OFFER_TIMEOUT_MS = 5_000L
        private const val RENDEZVOUS_TOKEN_BYTES = 4
        private const val SERVICE_DATA_BYTES = 4 + RENDEZVOUS_TOKEN_BYTES
        private val SERVICE_UUID = ParcelUuid.fromString("7e64746e-4348-4154-4e55-763200000001")
    }
}
