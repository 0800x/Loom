package app.loom.messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Opt-in keep-alive for the messaging connection.
 *
 * Loom receives messages over a foreground WebSocket owned by the Flutter
 * engine. Android suspends that engine shortly after the app is swiped away,
 * which silently stops notifications. This minimal foreground service keeps
 * the process (and therefore the socket) alive after the task is removed.
 *
 * This is still not push: if the OS kills the process or the device
 * restarts, nothing arrives until Loom is opened again.
 */
class MessagingForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        running = true
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Background connection", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Keeps Loom connected to your home node so messages arrive while the app is closed"
                    lockscreenVisibility = Notification.VISIBILITY_SECRET
                    setShowBadge(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
            else Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_message)
            .setContentTitle(getString(R.string.loom_stay_connected_title))
            .setContentText(getString(R.string.loom_stay_connected_text))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(tap)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val CHANNEL = "loom_connect_v1"
        const val NOTIFICATION_ID = 41

        @Volatile
        private var running = false

        fun isRunning(): Boolean = running

        fun start(context: Context) {
            val intent = Intent(context, MessagingForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MessagingForegroundService::class.java))
        }
    }
}
