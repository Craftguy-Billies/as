package com.billiez.vibecode

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DirectReplyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    companion object {
        const val CHANNEL_NAME = "com.billiez.vibecode/direct_reply"
        const val NOTIFICATION_CHANNEL_ID = "vibecode_task_complete"
        const val NOTIFICATION_CHANNEL_NAME = "Task Complete"
        const val KEY_TEXT_REPLY = "key_text_reply"
        const val EXTRA_TASK_ID = "extra_task_id"
        const val EXTRA_REPLY_ACTION = "com.billiez.vibecode.REPLY_ACTION"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)

        createNotificationChannel()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showCompletionNotification" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                val title = call.argument<String>("title") ?: "Task Complete"
                val body = call.argument<String>("body") ?: ""
                showNotification(taskId, title, body)
                result.success(true)
            }
            "dismissNotification" -> {
                val taskId = call.argument<String>("taskId") ?: ""
                dismissNotification(taskId)
                result.success(true)
            }
            "getPendingReplies" -> {
                val replies = DirectReplyReceiver.consumePendingReplies()
                result.success(replies.map { mapOf(
                    "taskId" to (it["taskId"] ?: ""),
                    "message" to (it["message"] ?: "")
                ) })
            }
            else -> result.notImplemented()
        }
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for completed VibeCode tasks"
            enableVibration(true)
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun showNotification(taskId: String, title: String, body: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Tap to open app
        val tapIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            putExtra(EXTRA_TASK_ID, taskId)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val tapPendingIntent = PendingIntent.getActivity(
            context, taskId.hashCode(), tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Reply action with RemoteInput
        val remoteInput = RemoteInput.Builder(KEY_TEXT_REPLY)
            .setLabel("Reply")
            .build()

        val replyIntent = Intent(EXTRA_REPLY_ACTION).apply {
            putExtra(EXTRA_TASK_ID, taskId)
            `package` = context.packageName
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context, taskId.hashCode() + 1, replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPendingIntent
        ).addRemoteInput(remoteInput).build()

        val notification = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(tapPendingIntent)
            .addAction(replyAction)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        manager.notify(taskId.hashCode(), notification)
    }

    private fun dismissNotification(taskId: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(taskId.hashCode())
    }
}
