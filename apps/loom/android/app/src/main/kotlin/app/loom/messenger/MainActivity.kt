package app.loom.messenger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var wallpaperMotion: LoomWallpaperMotion? = null
    private var wallpaperMotionChannel: EventChannel? = null
    private var recoveryExport: LoomRecoveryExportBridge? = null
    private var attachmentExport: LoomAttachmentExportBridge? = null
    private var attachmentExportChannel: MethodChannel? = null
    private var recoveryExportChannel: MethodChannel? = null
    private var appLock: LoomAppLockBridge? = null
    private var appLockChannel: MethodChannel? = null
    private var messageChannel: MethodChannel? = null
    private var groupLinkChannel: MethodChannel? = null
    private var groupLinkReady = false
    private var messageNotifications: LoomMessageNotifications? = null
    private var callChannel: MethodChannel? = null
    private var bleChannel: MethodChannel? = null
    private var bleBridge: LoomBleBridge? = null
    private var wifiDirectChannel: MethodChannel? = null
    private var wifiDirectBridge: LoomWifiDirectBridge? = null
    private var wifiAwareChannel: MethodChannel? = null
    private var wifiAwareBridge: LoomWifiAwareBridge? = null
    private var stateWrappingChannel: MethodChannel? = null
    private var stateWrappingBridge: LoomStateWrappingBridge? = null
    private var defaultNetworkChannel: EventChannel? = null
    private var defaultNetworkBridge: LoomDefaultNetworkBridge? = null
    private var pendingCallAction: Pair<String, String>? = null
    private var callBridgeReady = false
    private var pendingIncomingNotification: Map<*, *>? = null
    private val ringback = CallRingback()
    private var ongoingCall = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/maps")
            .setMethodCallHandler(LoomMapLauncher(this)::handle)
        groupLinkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/group_links").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "initialLink") {
                    groupLinkReady = true
                    val link = intent?.dataString?.takeIf { it.startsWith("loom://group/join?") }
                    result.success(link)
                    if (link != null) intent?.data = null
                } else result.notImplemented()
            }
        }
        wallpaperMotion = LoomWallpaperMotion(this).also { bridge ->
            wallpaperMotionChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/wallpaper_motion").also { it.setStreamHandler(bridge) }
        }
        attachmentExport = LoomAttachmentExportBridge(this).also { bridge ->
            attachmentExportChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/attachment_export").also { it.setMethodCallHandler(bridge::handle) }
        }
        recoveryExport = LoomRecoveryExportBridge(this).also { bridge ->
            recoveryExportChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/recovery_export").also {
                it.setMethodCallHandler(bridge::handle)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/keyboard_media")
            .setMethodCallHandler { call, result ->
                if (call.method != "readKeyboardImage") { result.notImplemented(); return@setMethodCallHandler }
                val uri = android.net.Uri.parse(call.argument<String>("uri") ?: "")
                if (uri.scheme != "content") { result.error("invalid_uri", "Only keyboard content URIs are supported", null); return@setMethodCallHandler }
                Thread {
                    try {
                        val mime = contentResolver.getType(uri)
                        require(mime in setOf("image/gif", "image/png", "image/jpeg", "image/webp"))
                        val bytes = contentResolver.openInputStream(uri)?.use { input ->
                            val output = java.io.ByteArrayOutputStream()
                            val buffer = ByteArray(8192)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                require(output.size() + count <= 32 * 1024 * 1024)
                                output.write(buffer, 0, count)
                            }
                            output.toByteArray()
                        } ?: throw IllegalStateException("Content unavailable")
                        runOnUiThread { result.success(bytes) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("content_unavailable", "Keyboard image unavailable or too large", null) }
                    }
                }.start()
            }
        appLock = LoomAppLockBridge(this).also { bridge ->
            appLockChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LoomAppLockBridge.CHANNEL).also { channel ->
                channel.setMethodCallHandler(bridge::handle)
                bridge.onLocked = { attachmentExport?.cancel(); channel.invokeMethod("locked", null) }
            }
        }
        messageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loom/notifications").also { channel ->
            messageNotifications = LoomMessageNotifications(this, channel).also { bridge -> channel.setMethodCallHandler(bridge::handle) }
        }
        callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result -> handleCallMethod(call, result) }
        }
        bleBridge = LoomBleBridge(this).also { bridge ->
            bleChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LoomBleBridge.CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (!bridge.handle(call, result)) result.notImplemented()
                }
            }
        }
        wifiDirectBridge = LoomWifiDirectBridge(this).also { bridge ->
            wifiDirectChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LoomWifiDirectBridge.CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (!bridge.handle(call, result)) result.notImplemented()
                }
            }
        }
        wifiAwareBridge = LoomWifiAwareBridge(this).also { bridge ->
            wifiAwareChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LoomWifiAwareBridge.CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (!bridge.handle(call, result)) result.notImplemented()
                }
            }
        }
        stateWrappingBridge = LoomStateWrappingBridge(this).also { bridge ->
            stateWrappingChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LoomStateWrappingBridge.CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (!bridge.handle(call, result)) result.notImplemented()
                }
            }
        }
        defaultNetworkBridge = LoomDefaultNetworkBridge(this).also { bridge ->
            defaultNetworkChannel = EventChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LoomDefaultNetworkBridge.CHANNEL,
            ).also { channel ->
                channel.setStreamHandler(bridge)
            }
        }
        prepareNotificationChannels()
        deliverAction(intent)
        messageNotifications?.consume(intent)
    }

    override fun onResume() {
        super.onResume()
        wallpaperMotion?.start()
        appLock?.onResume()
    }

    override fun onPause() {
        appLock?.onPause()
        wallpaperMotion?.pause()
        super.onPause()
    }

    override fun onStop() {
        appLock?.onStop()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.takeIf { it.startsWith("loom://group/join?") }?.let { link ->
            if (groupLinkReady) {
                groupLinkChannel?.invokeMethod("link", link)
                intent.data = null
            }
        }
        deliverAction(intent)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == 9041) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                pendingIncomingNotification?.let { showIncomingCall(it) }
            }
            return
        }
        if (bleBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        if (wifiDirectBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        if (wifiAwareBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (attachmentExport?.onActivityResult(requestCode, resultCode, data) == true) return
        if (recoveryExport?.onActivityResult(requestCode, resultCode, data) == true) return
        if (bleBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        if (wifiDirectBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        if (wifiAwareBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        wallpaperMotion?.stop()
        wallpaperMotionChannel?.setStreamHandler(null)
        wallpaperMotionChannel = null
        wallpaperMotion = null
        attachmentExport?.cancel()
        attachmentExport = null
        attachmentExportChannel?.setMethodCallHandler(null)
        attachmentExportChannel = null
        recoveryExportChannel?.setMethodCallHandler(null)
        recoveryExportChannel = null
        recoveryExport?.dispose()
        recoveryExport = null
        groupLinkReady = false
        groupLinkChannel?.setMethodCallHandler(null)
        groupLinkChannel = null
        ringback.stop()
        messageChannel?.setMethodCallHandler(null)
        messageChannel = null
        messageNotifications = null
        pendingIncomingNotification?.get("callId")?.let {
            notificationManager().cancel(notificationId(it as String))
        }
        pendingIncomingNotification = null
        defaultNetworkChannel?.setStreamHandler(null)
        defaultNetworkChannel = null
        defaultNetworkBridge?.shutdown()
        defaultNetworkBridge = null
        stateWrappingChannel?.setMethodCallHandler(null)
        stateWrappingChannel = null
        appLock?.dispose()
        appLockChannel?.setMethodCallHandler(null)
        stateWrappingBridge?.shutdown()
        stateWrappingBridge = null
        wifiAwareChannel?.setMethodCallHandler(null)
        wifiAwareChannel = null
        wifiAwareBridge?.shutdown()
        wifiAwareBridge = null
        wifiDirectChannel?.setMethodCallHandler(null)
        wifiDirectChannel = null
        wifiDirectBridge?.shutdown()
        wifiDirectBridge = null
        bleChannel?.setMethodCallHandler(null)
        bleChannel = null
        bleBridge?.shutdown()
        bleBridge = null
        callChannel?.setMethodCallHandler(null)
        callChannel = null
        super.onDestroy()
    }

    private fun handleCallMethod(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "prepare" -> {
                    prepareNotificationChannels()
                    callBridgeReady = true
                    val pending = pendingCallAction
                    pendingCallAction = null
                    result.success(pending?.let { (action, callId) -> mapOf("action" to action, "callId" to callId) })
                }
                "openIncomingSettings" -> {
                    prepareNotificationChannels()
                    val settings = if (Build.VERSION.SDK_INT >= 26) {
                        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, INCOMING_CHANNEL)
                    } else {
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(android.net.Uri.parse("package:$packageName"))
                    }
                    startActivity(settings)
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestCallNotificationPermission()
                    result.success(null)
                }
                "showIncoming" -> {
                    showIncomingCall(call.arguments as? Map<*, *>)
                    result.success(null)
                }
                "clearIncoming" -> {
                    val callId = (call.arguments as? Map<*, *>)?.get("callId") as? String
                    if (!callId.isNullOrBlank()) notificationManager().cancel(notificationId(callId))
                    if (pendingIncomingNotification?.get("callId") == callId) pendingIncomingNotification = null
                    result.success(null)
                }
                "startOngoing" -> {
                    val args = call.arguments as? Map<*, *>
                    val callId = args?.get("callId") as? String ?: "active"
                    val peerName = args?.get("peerName") as? String ?: "Loom call"
                    val video = args?.get("video") as? Boolean ?: false
                    val microphone = args?.get("microphoneActive") as? Boolean ?: true
                    val camera = args?.get("cameraActive") as? Boolean ?: video
                    startCallForegroundService(callId, peerName, video, microphone, camera)
                    ongoingCall = true
                    result.success(null)
                }
                "stopOngoing" -> {
                    ringback.stop()
                    stopService(Intent(this, CallForegroundService::class.java))
                    ongoingCall = false
                    result.success(null)
                }
                "prepareMediaPlayback" -> {
                    if (ongoingCall) { result.error("call_active", "End the call before playing media", null); return }
                    val audio = getSystemService(AudioManager::class.java)
                    if (Build.VERSION.SDK_INT >= 31) audio.clearCommunicationDevice()
                    audio.mode = AudioManager.MODE_NORMAL
                    volumeControlStream = AudioManager.STREAM_MUSIC
                    result.success(null)
                }
                "setRingback" -> {
                    ringback.setPlaying((call.arguments as? Map<*, *>)?.get("playing") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("call_platform_error", error.message, null)
        }
    }

    private fun showIncomingCall(args: Map<*, *>?) {
        ringback.stop()
        val callId = args?.get("callId") as? String ?: return
        val callerName = args["callerName"] as? String ?: "Loom"
        val callerAddress = args["callerAddress"] as? String ?: ""
        val video = args["video"] as? Boolean ?: false
        val expiresAt = (args["expiresAt"] as? Number)?.toLong() ?: (System.currentTimeMillis() + 45_000L)
        val remaining = expiresAt - System.currentTimeMillis()
        if (remaining <= 0) {
            notificationManager().cancel(notificationId(callId))
            pendingIncomingNotification = null
            return
        }
        pendingIncomingNotification = args.toMap()
        prepareNotificationChannels()

        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            notificationId(callId) + 1,
            openIntent,
            pendingFlags(),
        )
        // Activity PendingIntents avoid Android 12's notification trampoline
        // restriction. Dart keeps actions queued through App Lock as before.
        val acceptPending = callActionIntent("accept", callId, 2)
        val declinePending = callActionIntent("decline", callId, 3)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, INCOMING_CHANNEL)
        } else {
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(callerName)
            .setContentText(if (video) "Incoming Loom video call" else "Incoming Loom audio call")
            .setSubText(if (callerAddress.isBlank()) null else callerAddress)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(false)
            // A silent update combined with FLAG_INSISTENT cancels the
            // currently looping ringtone in Android's attention helper.
            // Insistent updates already preserve the playing sound instead
            // of restarting it; keep peer hydration / lock redaction audible.
            .setOnlyAlertOnce(false)
            .setContentIntent(openPending)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(
                Notification.CallStyle.forIncomingCall(
                    Person.Builder().setName(callerName.ifBlank { "Loom" }).build(),
                    declinePending,
                    acceptPending,
                ).setIsVideo(video),
            )
        } else {
            builder.addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Decline",
                    declinePending,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.sym_action_call,
                    "Accept",
                    acceptPending,
                ).build(),
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), ringtoneAttributes())
            builder.setVibrate(longArrayOf(0L, 500L, 1_000L))
        }

        val publicVersion = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, INCOMING_CHANNEL)
        } else {
            Notification.Builder(this)
        }.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Incoming Loom call")
            .setContentText(if (video) "Video call" else "Audio call")
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_MAX)
            .setContentIntent(openPending)
            .build()
        builder.setPublicVersion(publicVersion)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setTimeoutAfter(remaining.coerceAtMost(45_000L))

        if (canUseFullScreenIntent()) builder.setFullScreenIntent(openPending, true)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            val notification = builder.build().apply {
                flags = flags or Notification.FLAG_INSISTENT
            }
            traceIncomingAlertState()
            notificationManager().notify(notificationId(callId), notification)
        }
    }

    private fun startCallForegroundService(callId: String, peerName: String, video: Boolean, microphone: Boolean = true, camera: Boolean = video) {
        val service = Intent(this, CallForegroundService::class.java).apply {
            putExtra(CallForegroundService.EXTRA_CALL_ID, callId)
            putExtra(CallForegroundService.EXTRA_PEER_NAME, peerName)
            putExtra(CallForegroundService.EXTRA_VIDEO, video)
            putExtra(CallForegroundService.EXTRA_MICROPHONE_ACTIVE, microphone)
            putExtra(CallForegroundService.EXTRA_CAMERA_ACTIVE, camera)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service) else startService(service)
    }

    private fun requestCallNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9041)
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return notificationManager().canUseFullScreenIntent()
    }

    private fun prepareNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager()
        manager.createNotificationChannel(
            NotificationChannel(
                INCOMING_CHANNEL,
                "Incoming calls",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Incoming Loom audio and video calls"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), ringtoneAttributes())
                enableVibration(true)
                vibrationPattern = longArrayOf(0L, 500L, 1_000L)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                ONGOING_CHANNEL,
                "Ongoing calls",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps an active Loom call running while you multitask"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    private fun deliverAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_CALL_ACTION) ?: return
        val callId = intent.getStringExtra(EXTRA_CALL_ID) ?: return
        notificationManager().cancel(notificationId(callId))
        if (pendingIncomingNotification?.get("callId") == callId) pendingIncomingNotification = null
        intent.removeExtra(EXTRA_CALL_ACTION)
        intent.removeExtra(EXTRA_CALL_ID)
        val channel = callChannel
        if (channel == null || !callBridgeReady) {
            pendingCallAction = action to callId
        } else {
            channel.invokeMethod(
                "callAction",
                mapOf("action" to action, "callId" to callId),
            )
        }
    }

    // Temporary device diagnostics: booleans/enums/counts only. Never log
    // channel URIs, peer identities, notification content or call identifiers.
    private fun traceIncomingAlertState() {
        runCatching {
            val manager = notificationManager()
            val audio = getSystemService(AudioManager::class.java)
            val channel = if (Build.VERSION.SDK_INT >= 26) manager.getNotificationChannel(INCOMING_CHANNEL) else null
            val defaultTone = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
            val vibratePermission = checkSelfPermission(Manifest.permission.VIBRATE) == PackageManager.PERMISSION_GRANTED
            Log.i("LoomCalls", "[LoomCalls] incoming_alert_state" +
                " importance=${channel?.importance ?: -1}" +
                " sound=${channel?.sound != null}" +
                " vibration=${channel?.shouldVibrate() ?: false}" +
                " vibrate_permission=$vibratePermission" +
                " default_ringtone=${defaultTone != null}" +
                " ringer_mode=${audio.ringerMode}" +
                " ring_volume=${audio.getStreamVolume(AudioManager.STREAM_RING)}" +
                " audio_mode=${audio.mode}" +
                " interruption_filter=${manager.currentInterruptionFilter}")
        }.onFailure { error ->
            Log.i("LoomCalls", "[LoomCalls] incoming_alert_state_failed:${error.javaClass.simpleName}")
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(NotificationManager::class.java)

    private fun ringtoneAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private fun callActionIntent(action: String, callId: String, offset: Int): PendingIntent {
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ACTION, action)
            putExtra(EXTRA_CALL_ID, callId)
        }
        return PendingIntent.getActivity(this, notificationId(callId) + offset, launch, pendingFlags())
    }

    companion object {
        const val CALL_CHANNEL = "loom/calls"
        // Channel sound/importance cannot be changed after creation. A new ID
        // lets existing installations receive the ringtone configuration.
        const val INCOMING_CHANNEL = "loom_incoming_calls_v2"
        const val ONGOING_CHANNEL = "loom_ongoing_calls"
        const val EXTRA_CALL_ACTION = "loom.call.action"
        const val EXTRA_CALL_ID = "loom.call.id"

        fun notificationId(callId: String): Int =
            12000 + (callId.hashCode() and 0x3fffffff) % 100000

        fun pendingFlags(): Int =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
    }
}


