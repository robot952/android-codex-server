package top.asdb.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Base64
import android.net.wifi.WifiManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the Flutter process eligible to run while SSH/Codex channels are
 * active and the activity is backgrounded.  Protocol state remains owned by
 * Dart; this service only supplies foreground process priority and a bounded
 * partial wake lock.
 */
class ConnectionForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var flutterEngine: FlutterEngine? = null
    private var heartbeatChannel: MethodChannel? = null
    @Volatile
    private var serviceActive = false
    private val renewWakeLock = Runnable { acquireWakeLock() }
    private val sendHeartbeat = object : Runnable {
        override fun run() {
            heartbeatChannel?.invokeMethod("heartbeat", null)
            // A transient wake-lock loss must not permanently stop the
            // heartbeat loop. The service lifetime is independent from the
            // lock, which is reacquired by [renewWakeLock].
            if (serviceActive) {
                handler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
        acquireWifiLock()
        showForegroundNotification()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val connectionIntent = readConnectionIntent()
        DiagnosticLogBridge.append(
            "INFO",
            "Background",
            "service_start profiles=${connectionIntent.hostProfileIds.size} " +
                "agents=${connectionIntent.agentConnectionKeys.size} " +
                "startId=$startId",
        )
        if (connectionIntent.hostProfileIds.isEmpty()) {
            serviceActive = false
            handler.removeCallbacks(sendHeartbeat)
            heartbeatChannel = null
            DiagnosticLogBridge.append(
                "INFO",
                "Background",
                "service_stop_without_intent startId=$startId",
            )
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (wakeLock?.isHeld != true) acquireWakeLock()
        if (wifiLock?.isHeld != true) acquireWifiLock()
        serviceActive = true
        showForegroundNotification()
        handler.post {
            ensureFlutterEngine(connectionIntent)
            handler.removeCallbacks(sendHeartbeat)
            handler.post(sendHeartbeat)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceActive = false
        DiagnosticLogBridge.append("INFO", "Background", "service_destroy")
        handler.removeCallbacks(renewWakeLock)
        handler.removeCallbacks(sendHeartbeat)
        wakeLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        wakeLock = null
        wifiLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        wifiLock = null
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        handler.removeCallbacks(renewWakeLock)
        wakeLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        val powerManager = getSystemService(PowerManager::class.java)
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:ssh-connection",
        ).apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_TIMEOUT_MS)
        }
        handler.postDelayed(renewWakeLock, WAKE_LOCK_RENEWAL_MS)
    }

    /**
     * Keeps an active Wi-Fi transport usable while the device is dozing. The
     * foreground service and partial wake lock still cover non-Wi-Fi networks.
     */
    private fun acquireWifiLock() {
        val wifiManager = applicationContext.getSystemService(WIFI_SERVICE)
            as? WifiManager ?: return
        wifiLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        // FULL_LOW_LATENCY is optimized for an on-screen foreground app and
        // may be relinquished when the display turns off. SSH needs the Wi-Fi
        // radio to remain associated during lock-screen backgrounding, so use
        // the high-performance lock on every supported API level.
        @Suppress("DEPRECATION")
        val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = wifiManager.createWifiLock(mode, "$packageName:ssh-wifi").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.connection_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.connection_notification_channel_description)
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private fun showForegroundNotification() {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_connection_notification)
                .setContentTitle(getString(R.string.connection_notification_title))
                .setContentText(getString(R.string.connection_notification_text))
                .setContentIntent(contentIntent)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setDefaults(0)
                .setSound(null)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_connection_notification)
                .setContentTitle(getString(R.string.connection_notification_title))
                .setContentText(getString(R.string.connection_notification_text))
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureFlutterEngine(connectionIntent: BackgroundConnectionIntent) {
        FlutterEngineCache.getInstance().get(RETAINED_ENGINE_ID)?.let { engine ->
            flutterEngine = engine
            heartbeatChannel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                BACKGROUND_CHANNEL,
            )
            return
        }
        runCatching {
            DiagnosticLogBridge.initialize(applicationContext)
            val engine = FlutterEngine(applicationContext)
            FlutterEngineCache.getInstance().put(RETAINED_ENGINE_ID, engine)
            flutterEngine = engine
            heartbeatChannel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                BACKGROUND_CHANNEL,
            )
            try {
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault(),
                    connectionIntent.entrypointArguments(),
                )
            } catch (error: Throwable) {
                FlutterEngineCache.getInstance().remove(RETAINED_ENGINE_ID)
                engine.destroy()
                throw error
            }
            DiagnosticLogBridge.append(
                "INFO",
                "Background",
                "sticky_service_restored_flutter_engine " +
                    "profiles=${connectionIntent.hostProfileIds.size} " +
                    "agents=${connectionIntent.agentConnectionKeys.size}",
            )
        }.onFailure { error ->
            DiagnosticLogBridge.append(
                "WARN",
                "Background",
                "sticky_service_flutter_engine_restore_failed",
                error,
            )
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Some Android builds stop a foreground service when the task is
        // swiped away even with stopWithTask=false. Re-submit it while a
        // persisted connection intent still exists. Explicit stop clears the
        // intent before stopping, so it is not resurrected by this hook.
        val connectionIntent = readConnectionIntent()
        if (connectionIntent.hostProfileIds.isNotEmpty()) {
            start(
                this,
                connectionIntent.hostProfileIds,
                connectionIntent.agentConnectionKeys,
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun readConnectionIntent(): BackgroundConnectionIntent {
        val preferences = applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        val hosts = sanitizeIntentValues(
            preferences.getStringSet(KEY_HOST_PROFILE_IDS, emptySet()).orEmpty(),
            allowCompositeKey = false,
        )
        val agents = sanitizeIntentValues(
            preferences.getStringSet(KEY_AGENT_CONNECTION_KEYS, emptySet()).orEmpty(),
            allowCompositeKey = true,
        ).filterTo(linkedSetOf()) { key ->
            hosts.contains(key.substringBefore('\u0000'))
        }
        return BackgroundConnectionIntent(hosts, agents)
    }

    companion object {
        private const val CHANNEL_ID = "codex_connection"
        private const val NOTIFICATION_ID = 73
        private const val PREFERENCES_NAME = "agent_background_connection"
        private const val KEY_HOST_PROFILE_IDS = "host_profile_ids"
        private const val KEY_AGENT_CONNECTION_KEYS = "agent_connection_keys"
        private const val RETAINED_ENGINE_ID = "agent_connection_engine"
        private const val BACKGROUND_CHANNEL = "top.asdb.agent/background"
        private const val HOST_ARGUMENT_PREFIX = "--agent-background-host="
        private const val AGENT_ARGUMENT_PREFIX = "--agent-background-agent="
        private const val MAX_CONNECTION_INTENTS = 64
        private const val MAX_CONNECTION_INTENT_CHARS = 512
        private const val WAKE_LOCK_TIMEOUT_MS = 4 * 60 * 60_000L
        private const val WAKE_LOCK_RENEWAL_MS = 3 * 60 * 60_000L
        private const val HEARTBEAT_INTERVAL_MS = 10_000L

        fun start(
            context: Context,
            hostProfileIds: Collection<String>,
            agentConnectionKeys: Collection<String>,
        ) {
            val hosts = sanitizeIntentValues(hostProfileIds, allowCompositeKey = false)
            val agents = sanitizeIntentValues(
                agentConnectionKeys,
                allowCompositeKey = true,
            ).filterTo(linkedSetOf()) { key ->
                hosts.contains(key.substringBefore('\u0000'))
            }
            if (hosts.isEmpty()) {
                stop(context)
                return
            }
            check(
                context.applicationContext.getSharedPreferences(
                    PREFERENCES_NAME,
                    Context.MODE_PRIVATE,
                ).edit()
                    .putStringSet(KEY_HOST_PROFILE_IDS, hosts)
                    .putStringSet(KEY_AGENT_CONNECTION_KEYS, agents)
                    .commit(),
            ) { "无法保存后台连接恢复信息" }
            val intent = Intent(context, ConnectionForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.applicationContext.getSharedPreferences(
                PREFERENCES_NAME,
                Context.MODE_PRIVATE,
            ).edit().clear().commit()
            context.stopService(Intent(context, ConnectionForegroundService::class.java))
        }

        private fun sanitizeIntentValues(
            values: Collection<String>,
            allowCompositeKey: Boolean,
        ): LinkedHashSet<String> = values.asSequence()
            .map(String::trim)
            .filter { value ->
                value.isNotEmpty() &&
                    value.length <= MAX_CONNECTION_INTENT_CHARS &&
                    if (allowCompositeKey) {
                        val separator = value.indexOf('\u0000')
                        separator > 0 && separator < value.length - 1 &&
                            value.indexOf('\u0000', separator + 1) < 0
                    } else {
                        !value.contains('\u0000')
                    }
            }
            .distinct()
            .take(MAX_CONNECTION_INTENTS)
            .toCollection(linkedSetOf())
    }

    private data class BackgroundConnectionIntent(
        val hostProfileIds: Set<String>,
        val agentConnectionKeys: Set<String>,
    ) {
        fun entrypointArguments(): List<String> = buildList {
            hostProfileIds.sorted().forEach { value ->
                add(HOST_ARGUMENT_PREFIX + encode(value))
            }
            agentConnectionKeys.sorted().forEach { value ->
                add(AGENT_ARGUMENT_PREFIX + encode(value))
            }
        }

        private fun encode(value: String): String = Base64.encodeToString(
            value.toByteArray(Charsets.UTF_8),
            Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING,
        )
    }
}
