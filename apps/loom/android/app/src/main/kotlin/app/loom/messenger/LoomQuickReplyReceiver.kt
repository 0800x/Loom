package app.loom.messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.RemoteInput

/**
 * Forwards notification RemoteInput text to Dart. Encryption and message
 * submission remain owned by the Dart messaging controller.
 */
class LoomQuickReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val conversationId = intent.getStringExtra(LoomMessageNotifications.EXTRA)
            ?.trim()
            .orEmpty()
        if (conversationId.isEmpty()) return

        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(LoomMessageNotifications.KEY_QUICK_REPLY)
            ?.toString()
            ?.trim()
            .orEmpty()
        if (text.isEmpty()) return

        LoomMessageNotifications.forwardQuickReply(conversationId, text)
    }
}
