package top.asdb.codexremote

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import top.asdb.codexremote.data.AgentKind
import top.asdb.codexremote.diagnostics.DiagnosticLogger

data class TurnCompletion(
    val profileId: String,
    val agent: AgentKind,
    val profileName: String,
    val threadId: String,
    val threadTitle: String,
    val threadPreview: String,
)

object TurnCompletionNotifier {
    const val ACTION_OPEN_COMPLETED_THREAD = "top.asdb.codexremote.action.OPEN_COMPLETED_THREAD"
    const val EXTRA_PROFILE_ID = "completed_profile_id"
    const val EXTRA_AGENT = "completed_agent"
    const val EXTRA_THREAD_ID = "completed_thread_id"

    private const val CHANNEL_ID = "codex_turn_completion"
    private const val GROUP_KEY = "codex_turn_completions"

    @SuppressLint("MissingPermission")
    fun show(context: Context, completion: TurnCompletion) {
        if (!canPostNotifications(context)) {
            DiagnosticLogger.warn("Notification", "turn_completion_permission_missing")
            return
        }
        createChannel(context)
        val contentIntent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN_COMPLETED_THREAD
            data = Uri.Builder()
                .scheme("codexremote")
                .authority("turn-completed")
                .appendPath(completion.profileId)
                .appendPath(completion.agent.name)
                .appendPath(completion.threadId)
                .build()
            putExtra(EXTRA_PROFILE_ID, completion.profileId)
            putExtra(EXTRA_AGENT, completion.agent.name)
            putExtra(EXTRA_THREAD_ID, completion.threadId)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val requestCode = completionNotificationId(completion.profileId, completion.agent, completion.threadId)
        val pendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val detail = completion.threadTitle.ifBlank { completion.threadPreview }
            .ifBlank { "点击查看完成的会话" }
            .take(160)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_connection_notification)
            .setContentTitle("${completion.profileName} · 会话已完成")
            .setContentText(detail)
            .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setGroup(GROUP_KEY)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        runCatching {
            NotificationManagerCompat.from(context).notify(requestCode, notification)
        }.onSuccess {
            DiagnosticLogger.info(
                "Notification",
                "turn_completion_posted profile=${completion.profileId.take(8)} " +
                    "agent=${completion.agent.name} thread=${completion.threadId.take(8)}",
            )
        }.onFailure {
            DiagnosticLogger.error("Notification", "turn_completion_failed", it)
        }
    }

    fun cancel(context: Context, profileId: String, agent: AgentKind, threadId: String) {
        NotificationManagerCompat.from(context).cancel(completionNotificationId(profileId, agent, threadId))
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.turn_completion_notification_channel),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.turn_completion_notification_channel_description)
            setShowBadge(true)
        }
        NotificationManagerCompat.from(context).createNotificationChannel(channel)
    }

    private fun canPostNotifications(context: Context): Boolean =
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(context).areNotificationsEnabled()
}

internal fun completionNotificationId(profileId: String, agent: AgentKind, threadId: String): Int =
    NOTIFICATION_ID_RANGE_START +
        ((31 * (31 * profileId.hashCode() + agent.hashCode()) + threadId.hashCode()) and 0x00ff_ffff)

private const val NOTIFICATION_ID_RANGE_START = 10_000
