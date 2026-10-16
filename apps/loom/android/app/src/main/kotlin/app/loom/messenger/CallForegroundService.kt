package app.loom.messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class CallForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    MainActivity.ONGOING_CHANNEL,
                    "Ongoing calls",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callId = intent?.getStringExtra(EXTRA_CALL_ID) ?: "active"
        val peerName = intent?.getStringExtra(EXTRA_PEER_NAME) ?: "Loom call"
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        val microphone = intent?.getBooleanExtra(EXTRA_MICROPHONE_ACTIVE, true) ?: true
        val camera = intent?.getBooleanExtra(EXTRA_CAMERA_ACTIVE, video) ?: video
        val notification = buildNotification(callId, peerName, video)

        // Explicit camera/microphone FGS types are required on modern Android.
        // Use the typed overload only where both constants/API behavior are
        // stable; older releases keep the ordinary foreground notification.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            if (microphone) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (camera) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            startForeground(ONGOING_NOTIFICATION_ID, notification, type)
        } else {
            startForeground(ONGOING_NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(callId: String, peerName: String, video: Boolean): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            MainActivity.notificationId(callId) + 8,
            openIntent,
            MainActivity.pendingFlags(),
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.ONGOING_CHANNEL)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(peerName)
            .setContentText(if (video) "Loom video call in progress" else "Loom audio call in progress")
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPending)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val EXTRA_CALL_ID = "loom.call.service.id"
        const val EXTRA_PEER_NAME = "loom.call.service.peer"
        const val EXTRA_VIDEO = "loom.call.service.video"
        const val EXTRA_MICROPHONE_ACTIVE = "loom.call.service.microphone"
        const val EXTRA_CAMERA_ACTIVE = "loom.call.service.camera"
        private const val ONGOING_NOTIFICATION_ID = 11991
    }
}
