package app.loom.messenger

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Local notifications for already received ciphertext. This is not Push. */
class LoomMessageNotifications(private val activity: Activity, private val channel: MethodChannel) {
    private val manager get() = activity.getSystemService(NotificationManager::class.java)
    private var ready = false
    private var pending: String? = null
    init { consume(activity.intent) }
    fun consume(intent: Intent?) {
        val id = intent?.getStringExtra(EXTRA) ?: return
        intent.removeExtra(EXTRA)
        manager.cancel(tag(id), 1)
        if (ready) channel.invokeMethod("openConversation", id) else pending = id
    }

    /** Reports the outcome of the POST_NOTIFICATIONS dialog back to Dart. */
    fun onPermissionResult(granted: Boolean) {
        if (ready) channel.invokeMethod("permissionResult", granted)
    }

    private fun prepare() {
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "New encrypted messages while Loom is running"
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                enableVibration(true)
                setSound(Settings.System.DEFAULT_NOTIFICATION_URI, android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION).build())
            })
    }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "prepare" -> { prepare(); ready = true; result.success(pending); pending = null }
                "enable" -> {
                    prepare()
                    if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
                    }
                    result.success(null)
                }
                "status" -> result.success(mapOf("supported" to true, "enabled" to manager.areNotificationsEnabled(), "push" to false))
                "openSettings" -> {
                    prepare()
                    val settings = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + activity.packageName))
                    activity.startActivity(settings)
                    result.success(null)
                }
                "clearMessage" -> { (call.arguments as? String)?.let { manager.cancel(tag(it), 1) }; result.success(null) }
                "showMessage" -> { show(call.arguments as? Map<*, *>); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("notifications_unavailable", "System notifications unavailable", null) }
    }
    private fun tag(id: String) = "loom.message.$id"
    private fun show(args: Map<*, *>?) {
        val id = args?.get("conversationId") as? String ?: return
        if (!manager.areNotificationsEnabled()) return
        prepare()
        val intent = Intent(activity, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA, id)
            data = android.net.Uri.parse("loom://notification/" + android.net.Uri.encode(id))
        }
        val tap = PendingIntent.getActivity(activity, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, CHANNEL) else Notification.Builder(activity)
        builder.setSmallIcon(R.drawable.ic_stat_message).setContentTitle((args["title"] as? String ?: "Loom").take(100))
            .setContentText("New encrypted message").setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true).setContentIntent(tap)
            .setOnlyAlertOnce(false).setPriority(Notification.PRIORITY_HIGH)
            .setPublicVersion((if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, CHANNEL) else Notification.Builder(activity))
                .setSmallIcon(R.drawable.ic_stat_message).setContentTitle("Loom").setContentText("New encrypted message").build())
        if (Build.VERSION.SDK_INT < 26) builder.setDefaults(Notification.DEFAULT_SOUND or Notification.DEFAULT_VIBRATE)
        manager.notify(tag(id), 1, builder.build())
    }
    companion object {
        const val CHANNEL = "loom_messages_v1"
        const val EXTRA = "loom_message_conversation"
        const val PERMISSION_REQUEST_CODE = 9042
    }
}
