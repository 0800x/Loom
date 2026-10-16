package app.loom.messenger

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(MainActivity.EXTRA_CALL_ACTION) ?: return
        val callId = intent.getStringExtra(MainActivity.EXTRA_CALL_ID) ?: return

        context.getSystemService(NotificationManager::class.java)
            .cancel(MainActivity.notificationId(callId))

        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_CALL_ACTION, action)
            putExtra(MainActivity.EXTRA_CALL_ID, callId)
        }
        context.startActivity(launch)
    }

    companion object {
        fun pendingIntent(
            context: Context,
            action: String,
            callId: String,
            requestOffset: Int,
        ): PendingIntent {
            val intent = Intent(context, CallActionReceiver::class.java).apply {
                putExtra(MainActivity.EXTRA_CALL_ACTION, action)
                putExtra(MainActivity.EXTRA_CALL_ID, callId)
            }
            return PendingIntent.getBroadcast(
                context,
                MainActivity.notificationId(callId) + requestOffset,
                intent,
                MainActivity.pendingFlags(),
            )
        }
    }
}
