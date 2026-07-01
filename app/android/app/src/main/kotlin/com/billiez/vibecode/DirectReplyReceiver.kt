package com.billiez.vibecode

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput

class DirectReplyReceiver : BroadcastReceiver() {

    companion object {
        const val KEY_TEXT_REPLY = "key_text_reply"
        const val EXTRA_TASK_ID = "extra_task_id"

        // Stores pending replies until Flutter picks them up
        private val pendingReplies = mutableListOf<Map<String, String>>()

        fun consumePendingReplies(): List<Map<String, String>> {
            val replies = pendingReplies.toList()
            pendingReplies.clear()
            return replies
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val taskId = intent.getStringExtra(EXTRA_TASK_ID) ?: return
        val remoteInput = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(KEY_TEXT_REPLY)?.toString() ?: return

        if (replyText.isNotBlank()) {
            pendingReplies.add(mapOf("taskId" to taskId, "message" to replyText))

            // Dismiss the notification
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as android.app.NotificationManager
            manager.cancel(taskId.hashCode())
        }
    }
}
