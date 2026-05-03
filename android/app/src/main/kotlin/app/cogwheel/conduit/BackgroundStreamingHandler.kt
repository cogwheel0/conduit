package app.cogwheel.conduit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.Manifest
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*

private data class StreamingLease(
    val id: String,
    val kind: String,
    val requiresMicrophone: Boolean,
) {
    val isVoice: Boolean get() = kind == KIND_VOICE
    val isSocket: Boolean get() = id == SOCKET_KEEPALIVE_ID

    fun toPlatformMap(): Map<String, Any> = mapOf(
        "id" to id,
        "kind" to kind,
        "requiresMicrophone" to requiresMicrophone,
    )

    companion object {
        const val KIND_CHAT = "chat"
        const val KIND_VOICE = "voice"
        const val SOCKET_KEEPALIVE_ID = "socket-keepalive"
    }
}

/**
 * Foreground service for keeping the app alive during streaming operations.
 *
 * This service provides reliable background execution on Android by:
 * 1. Running as a foreground service with a notification (required by Android)
 * 2. Acquiring a partial wake lock to prevent CPU sleep during active streaming
 * 3. Supporting both dataSync and microphone foreground service types
 *
 * Key behaviors:
 * - For chat streaming: Runs with dataSync type, acquires wake lock
 * - For voice calls: Runs with microphone type (if permission granted), acquires wake lock
 * - Idle sockets: Do not start native background execution
 *
 * Android 14+ (UPSIDE_DOWN_CAKE) limitation:
 * - dataSync foreground services are limited to 6 hours
 * - We stop at 5 hours to provide a 1-hour buffer and notify the Flutter layer
 */
class BackgroundStreamingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var activeLeases: List<StreamingLease> = emptyList()
    private var isForeground = false
    private var currentForegroundType: Int = 0
    private var foregroundStartTime: Long = 0

    companion object {
        const val CHANNEL_ID = "conduit_streaming_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "START_STREAMING"
        const val ACTION_STOP = "STOP_STREAMING"
        const val EXTRA_REQUIRES_MICROPHONE = "requiresMicrophone"
        const val EXTRA_STREAM_COUNT = "streamCount"
        const val EXTRA_LEASE_IDS = "leaseIds"
        const val EXTRA_LEASE_KINDS = "leaseKinds"
        const val EXTRA_MIC_LEASE_IDS = "micLeaseIds"
        
        const val ACTION_TIME_LIMIT_APPROACHING = "app.cogwheel.conduit.TIME_LIMIT_APPROACHING"
        const val ACTION_MIC_PERMISSION_FALLBACK = "app.cogwheel.conduit.MIC_PERMISSION_FALLBACK"
        const val EXTRA_REMAINING_MINUTES = "remainingMinutes"
    }

    override fun onCreate() {
        super.onCreate()
        println("BackgroundStreamingService: Service created")

        // CRITICAL: Enter foreground IMMEDIATELY to satisfy Android's 5s timeout.
        // Do this before ANY other initialization to minimize the risk of
        // ForegroundServiceDidNotStartInTimeException.
        try {
            val initialType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
            if (!isForeground) {
                // Channel should already exist (created in ConduitApplication)
                // but ensure it exists as a fallback
                ensureNotificationChannel()
                val notification = createMinimalNotification()
                val success = startForegroundInternal(notification, initialType)
                if (!success) {
                    // startForegroundInternal returned false (caught internal exception)
                    // Throw to trigger the fallback handler
                    throw IllegalStateException("startForegroundInternal returned false")
                }
            }
        } catch (e: Exception) {
            // Last resort: try to enter foreground with absolute minimal setup
            println("BackgroundStreamingService: Error in onCreate, attempting fallback: ${e.message}")
            try {
                // Must ensure channel exists before creating notification on Android O+
                // Otherwise startForeground throws "Bad notification" error
                ensureNotificationChannel()
                val fallbackNotification = NotificationCompat.Builder(this, CHANNEL_ID)
                    .setContentTitle("Conduit")
                    .setSmallIcon(R.drawable.ic_hub)
                    .setSilent(true)
                    .setOngoing(true)  // Prevent user from dismissing foreground service notification
                    .build()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIFICATION_ID,
                        fallbackNotification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                    currentForegroundType = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else {
                    @Suppress("DEPRECATION")
                    startForeground(NOTIFICATION_ID, fallbackNotification)
                }
                isForeground = true
                foregroundStartTime = System.currentTimeMillis()
            } catch (fallbackError: Exception) {
                println("BackgroundStreamingService: Fallback also failed: ${fallbackError.message}")
                // All attempts exhausted - now notify Flutter of the failure
                // This ensures we don't prematurely notify before trying fallback
                sendFailureNotification(fallbackError)
                // Service will be killed by system, but at least we tried
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        activeLeases = readLeases(intent)

        if (activeLeases.isEmpty() && action != ACTION_STOP) {
            println("BackgroundStreamingService: No leases in start command; stopping")
            stopStreaming()
            return START_NOT_STICKY
        }

        val desiredType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            resolveForegroundServiceType(intent)
        } else {
            0
        }

        // Always enter foreground as early as possible to avoid the 5s timeout
        // even when stop/keep-alive races deliver a STOP intent first.
        val needsTypeUpdate = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            currentForegroundType != desiredType

        if (!isForeground || needsTypeUpdate) {
            val notification = createMinimalNotification()
            val enteredForeground = if (!isForeground) {
                startForegroundInternal(notification, desiredType)
            } else {
                updateForegroundType(notification, desiredType)
            }

            if (!enteredForeground) {
                stopSelf()
                return START_NOT_STICKY
            }

            // If no streams are active after entering foreground, shut down to
            // avoid lingering foreground instances that could trigger
            // DidNotStopInTime exceptions.
            if (activeLeases.isEmpty()) {
                stopStreaming()
                return START_NOT_STICKY
            }
        }

        when (action) {
            ACTION_STOP -> {
                stopStreaming()
                return START_NOT_STICKY
            }
            "KEEP_ALIVE" -> {
                keepAlive()
                return START_STICKY
            }
            ACTION_START -> {
                if (activeLeases.isNotEmpty()) {
                    updateWakeLock()
                    println("BackgroundStreamingService: Started foreground service")
                } else {
                    println("BackgroundStreamingService: No active streams; skipping wake lock")
                }
            }
        }

        return START_STICKY
    }

    private fun readLeases(intent: Intent?): List<StreamingLease> {
        val ids = intent?.getStringArrayListExtra(EXTRA_LEASE_IDS)
        if (!ids.isNullOrEmpty()) {
            val kinds = intent.getStringArrayListExtra(EXTRA_LEASE_KINDS) ?: arrayListOf()
            val micIds = intent.getStringArrayListExtra(EXTRA_MIC_LEASE_IDS)?.toSet() ?: emptySet()
            return ids.mapIndexedNotNull { index, id ->
                if (id == StreamingLease.SOCKET_KEEPALIVE_ID) {
                    null
                } else {
                    StreamingLease(
                        id = id,
                        kind = kinds.getOrNull(index) ?: StreamingLease.KIND_CHAT,
                        requiresMicrophone = micIds.contains(id),
                    )
                }
            }
        }

        val count = intent?.getIntExtra(EXTRA_STREAM_COUNT, 0) ?: 0
        val requiresMic = intent?.getBooleanExtra(EXTRA_REQUIRES_MICROPHONE, false) ?: false
        return (0 until count).map { index ->
            StreamingLease(
                id = "legacy-$index",
                kind = if (requiresMic) StreamingLease.KIND_VOICE else StreamingLease.KIND_CHAT,
                requiresMicrophone = requiresMic,
            )
        }
    }

    private fun startForegroundInternal(notification: Notification, type: Int): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, type)
                currentForegroundType = type
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
            isForeground = true
            foregroundStartTime = System.currentTimeMillis()
            println("BackgroundStreamingService: Foreground service started at $foregroundStartTime")
            true
        } catch (e: Exception) {
            // Catch all exceptions including ForegroundServiceStartNotAllowedException
            println("BackgroundStreamingService: Failed to enter foreground: ${e.javaClass.simpleName}: ${e.message}")
            // Don't notify Flutter here - let caller handle fallback attempts first.
            // Only notify after all attempts (primary + fallback) have been exhausted.
            false
        }
    }
    
    private fun sendFailureNotification(e: Exception) {
        // Send broadcast intent to notify MainActivity
        val intent = Intent("app.cogwheel.conduit.FOREGROUND_SERVICE_FAILED")
        intent.putExtra("error", e.message ?: "Unknown error")
        intent.putExtra("errorType", e.javaClass.simpleName)
        sendBroadcast(intent)
    }

    private fun updateForegroundType(notification: Notification, type: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return try {
            startForeground(NOTIFICATION_ID, notification, type)
            currentForegroundType = type
            true
        } catch (e: Exception) {
            println("BackgroundStreamingService: Unable to update foreground type: ${e.message}")
            sendFailureNotification(e)
            false
        }
    }

    private fun resolveForegroundServiceType(intent: Intent?): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0

        val requiresMicrophone =
            activeLeases.any { it.requiresMicrophone || it.isVoice } ||
                (intent?.getBooleanExtra(EXTRA_REQUIRES_MICROPHONE, false) ?: false)
        if (requiresMicrophone) {
            if (hasRecordAudioPermission()) {
                return ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            }
            println("BackgroundStreamingService: Microphone permission missing; falling back to data sync type")
            // Notify handler about the permission fallback
            sendBroadcast(Intent(ACTION_MIC_PERMISSION_FALLBACK))
        }

        return ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    }

    private fun hasRecordAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun createMinimalNotification(): Notification {
        ensureNotificationChannel()

        // Create PendingIntent to open app when notification is tapped
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        // Create a minimal, silent notification (required for foreground service)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Conduit")
            .setContentText("Background service active")
            .setSmallIcon(R.drawable.ic_hub)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Background Service",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Background service for Conduit"
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
        }

        manager.createNotificationChannel(channel)
    }
    
    private val wakeLockHandler = Handler(Looper.getMainLooper())
    private var wakeLockTimeoutRunnable: Runnable? = null
    
    private fun updateWakeLock() {
        if (activeLeases.isEmpty()) {
            releaseWakeLock()
            return
        }

        val timeoutMs = when {
            activeLeases.any { it.isVoice || it.requiresMicrophone } -> 7 * 60 * 1000L
            activeLeases.any { !it.isSocket } -> 7 * 60 * 1000L
            else -> 0L
        }

        if (timeoutMs <= 0L) {
            releaseWakeLock()
            return
        }

        acquireWakeLock(timeoutMs)
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        if (wakeLock?.isHeld == true) {
            scheduleWakeLockTimeout(timeoutMs)
            return
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Conduit::StreamingWakeLock"
        ).apply {
            // Disable reference counting for deterministic single-holder behavior
            // This prevents accumulation if acquireWakeLock is called multiple times
            setReferenceCounted(false)
            acquire()
        }

        scheduleWakeLockTimeout(timeoutMs)
        println("BackgroundStreamingService: Wake lock acquired (${timeoutMs / 1000}s timeout)")
    }

    private fun scheduleWakeLockTimeout(timeoutMs: Long) {
        wakeLockTimeoutRunnable?.let { wakeLockHandler.removeCallbacks(it) }
        wakeLockTimeoutRunnable = Runnable {
            println("BackgroundStreamingService: Wake lock timeout reached, releasing")
            releaseWakeLock()
        }
        wakeLockHandler.postDelayed(wakeLockTimeoutRunnable!!, timeoutMs)
    }
    
    private fun releaseWakeLock() {
        // Cancel manual timeout handler
        wakeLockTimeoutRunnable?.let { wakeLockHandler.removeCallbacks(it) }
        wakeLockTimeoutRunnable = null
        
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    println("BackgroundStreamingService: Wake lock released")
                }
            }
        } catch (e: Exception) {
            // Wake lock may already be released
            println("BackgroundStreamingService: Wake lock release exception: ${e.message}")
        }
        wakeLock = null
    }
    
    private fun keepAlive() {
        // Check if we've hit Android 14's dataSync time limit
        // We stop at 5 hours to provide a 1-hour buffer before Android's 6-hour hard limit
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && isForeground) {
            val uptime = System.currentTimeMillis() - foregroundStartTime
            val fiveHours = 5 * 60 * 60 * 1000L
            
            if (uptime > fiveHours) {
                println("BackgroundStreamingService: Time limit reached (${uptime / 3600000}h), stopping service")
                // Notify Flutter before stopping
                sendBroadcast(Intent(ACTION_TIME_LIMIT_APPROACHING).apply {
                    putExtra(EXTRA_REMAINING_MINUTES, 0)
                })
                stopStreaming()
                return
            }
        }
        
        if (activeLeases.isNotEmpty()) {
            updateWakeLock()
            println(
                "BackgroundStreamingService: Keep alive - " +
                    "${activeLeases.size} active leases",
            )
        } else {
            releaseWakeLock()
            println("BackgroundStreamingService: Keep alive without active leases")
        }
    }
    
    private fun stopStreaming() {
        println("BackgroundStreamingService: Stopping service...")
        activeLeases = emptyList()
        releaseWakeLock()
        
        if (isForeground) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            } catch (e: Exception) {
                println("BackgroundStreamingService: Error stopping foreground: ${e.message}")
            }
            isForeground = false
        }
        
        stopSelf()
        println("BackgroundStreamingService: Service stopped")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        println("BackgroundStreamingService: Task removed, stopping service")
        stopStreaming()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        println("BackgroundStreamingService: onDestroy called")
        if (isForeground) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            } catch (e: Exception) {
                println("BackgroundStreamingService: Error stopping foreground in onDestroy: ${e.message}")
            }
        }
        releaseWakeLock()
        activeLeases = emptyList()
        isForeground = false
        foregroundStartTime = 0
        super.onDestroy()
        println("BackgroundStreamingService: Service destroyed")
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

class BackgroundStreamingHandler(private val activity: MainActivity) : MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    private val activeLeases = linkedMapOf<String, StreamingLease>()
    private var backgroundJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var broadcastReceiver: android.content.BroadcastReceiver? = null
    private var receiverRegistered = false
    private var isActivityForeground = true
    private var isServiceRequested = false
    private var lifecycleObserverRegistered = false
    private val activityLifecycleObserver = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) {
            isActivityForeground = true

            // Foreground services are only needed once the activity is leaving
            // the foreground. Stop the service when the UI returns so active
            // streams can continue without a persistent notification.
            if (activeLeases.isNotEmpty()) {
                stopForegroundService()
            }
        }

        override fun onPause(owner: LifecycleOwner) {
            // Ignore configuration changes to avoid foreground-service churn
            // during rotations and other activity recreation events.
            if (activity.isChangingConfigurations) {
                return
            }

            isActivityForeground = false

            if (activeLeases.isNotEmpty() && !isServiceRequested) {
                startForegroundService()
            }
        }
    }
    
    companion object {
        private const val CHANNEL_NAME = "conduit/background_streaming"
    }

    fun setup(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        context = activity.applicationContext
        isActivityForeground = !activity.isFinishing

        createNotificationChannel()
        setupBroadcastReceiver()
        if (!lifecycleObserverRegistered) {
            activity.lifecycle.addObserver(activityLifecycleObserver)
            lifecycleObserverRegistered = true
        }
    }
    
    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }
    
    private fun setupBroadcastReceiver() {
        if (receiverRegistered) return
        
        broadcastReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    "app.cogwheel.conduit.FOREGROUND_SERVICE_FAILED" -> {
                        val error = intent.getStringExtra("error") ?: "Unknown error"
                        val errorType = intent.getStringExtra("errorType") ?: "Exception"
                        
                        println("BackgroundStreamingHandler: Service failure received: $errorType - $error")
                        
                        // Notify Flutter about the service failure
                        channel.invokeMethod("serviceFailed", mapOf(
                            "error" to error,
                            "errorType" to errorType,
                            "streamIds" to activeLeases.keys.toList()
                        ))
                        
                        // Clear active streams since service failed
                        activeLeases.clear()
                        isServiceRequested = false
                    }
                    
                    BackgroundStreamingService.ACTION_TIME_LIMIT_APPROACHING -> {
                        val remainingMinutes = intent.getIntExtra(
                            BackgroundStreamingService.EXTRA_REMAINING_MINUTES, -1
                        )
                        println("BackgroundStreamingHandler: Time limit approaching - $remainingMinutes minutes remaining")
                        
                        channel.invokeMethod("timeLimitApproaching", mapOf(
                            "remainingMinutes" to remainingMinutes
                        ))
                    }
                    
                    BackgroundStreamingService.ACTION_MIC_PERMISSION_FALLBACK -> {
                        println("BackgroundStreamingHandler: Microphone permission fallback triggered")
                        channel.invokeMethod("microphonePermissionFallback", null)
                    }
                }
            }
        }
        
        val filter = android.content.IntentFilter().apply {
            addAction("app.cogwheel.conduit.FOREGROUND_SERVICE_FAILED")
            addAction(BackgroundStreamingService.ACTION_TIME_LIMIT_APPROACHING)
            addAction(BackgroundStreamingService.ACTION_MIC_PERMISSION_FALLBACK)
        }
        
        // Use ContextCompat.registerReceiver for unified handling across API levels
        // RECEIVER_NOT_EXPORTED ensures security on all versions (internal broadcasts only)
        ContextCompat.registerReceiver(
            context,
            broadcastReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        receiverRegistered = true
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startBackgroundExecution" -> {
                val streamIds = call.argument<List<String>>("streamIds")
                val requiresMic = call.argument<Boolean>("requiresMicrophone") ?: false
                if (streamIds != null) {
                    val leases = parseMethodLeases(
                        call.argument<List<Any>>("leases"),
                        streamIds,
                        requiresMic,
                    )
                    if (startBackgroundExecution(leases)) {
                        result.success(null)
                    } else {
                        result.error(
                            "SERVICE_START_FAILED",
                            "Unable to start Android background streaming service",
                            null,
                        )
                    }
                } else {
                    result.error("INVALID_ARGS", "Stream IDs required", null)
                }
            }
            
            "stopBackgroundExecution" -> {
                val streamIds = call.argument<List<String>>("streamIds")
                if (streamIds != null) {
                    stopBackgroundExecution(streamIds)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGS", "Stream IDs required", null)
                }
            }
            
            "keepAlive" -> {
                keepAlive()
                result.success(null)
            }
            
            "checkNotificationPermission" -> {
                result.success(hasNotificationPermission())
            }
            
            "getActiveStreamCount" -> {
                // Return count for Flutter-native state reconciliation
                result.success(activeLeases.size)
            }

            "getActiveStreamLeases" -> {
                result.success(activeLeases.values.map { it.toPlatformMap() })
            }
            
            "stopAllBackgroundExecution" -> {
                // Stop all streams (used for reconciliation when orphaned service detected)
                val allStreams = activeLeases.keys.toList()
                stopBackgroundExecution(allStreams)
                result.success(null)
            }
            
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun startBackgroundExecution(leases: List<StreamingLease>): Boolean {
        for (lease in leases) {
            activeLeases[lease.id] = lease
        }

        if (activeLeases.isNotEmpty()) {
            if (isActivityForeground) {
                if (activeLeases.values.any { it.isVoice || it.requiresMicrophone }) {
                    if (!startForegroundService()) {
                        return false
                    }
                }
                startBackgroundMonitoring()
                return true
            }
            if (!startForegroundService()) {
                return false
            }
            startBackgroundMonitoring()
        }
        return true
    }

    private fun stopBackgroundExecution(streamIds: List<String>) {
        for (streamId in streamIds) {
            activeLeases.remove(streamId)
        }

        if (activeLeases.isEmpty()) {
            stopForegroundService()
            stopBackgroundMonitoring()
        } else if (isServiceRequested) {
            updateForegroundServiceLeases()
        }
    }

    private fun parseMethodLeases(
        rawLeases: List<Any>?,
        streamIds: List<String>,
        requiresMic: Boolean,
    ): List<StreamingLease> {
        if (!rawLeases.isNullOrEmpty()) {
            return rawLeases.mapNotNull { raw ->
                val map = raw as? Map<*, *> ?: return@mapNotNull null
                val id = map["id"] as? String ?: return@mapNotNull null
                if (id == StreamingLease.SOCKET_KEEPALIVE_ID) {
                    return@mapNotNull null
                }
                StreamingLease(
                    id = id,
                    kind = map["kind"] as? String ?: StreamingLease.KIND_CHAT,
                    requiresMicrophone = map["requiresMicrophone"] as? Boolean ?: false,
                )
            }
        }

        return streamIds
            .filter { it != StreamingLease.SOCKET_KEEPALIVE_ID }
            .map { id ->
                StreamingLease(
                    id = id,
                    kind = if (requiresMic) {
                        StreamingLease.KIND_VOICE
                    } else {
                        StreamingLease.KIND_CHAT
                    },
                    requiresMicrophone = requiresMic,
                )
            }
    }

    private fun startForegroundService(): Boolean {
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            putLeases(serviceIntent)
            serviceIntent.action = BackgroundStreamingService.ACTION_START

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            isServiceRequested = true
            return true
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to start foreground service: ${e.message}")
            notifyServiceFailure(e)
            activeLeases.clear()
            isServiceRequested = false
            stopBackgroundMonitoring()
            return false
        }
    }

    private fun stopForegroundService() {
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.action = BackgroundStreamingService.ACTION_STOP
            context.stopService(serviceIntent)
            isServiceRequested = false
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to stop foreground service: ${e.message}")
        }
    }

    private fun updateForegroundServiceLeases() {
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.action = "KEEP_ALIVE"
            putLeases(serviceIntent)
            context.startService(serviceIntent)
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to update foreground service leases: ${e.message}")
        }
    }

    private fun putLeases(intent: Intent) {
        val leases = activeLeases.values.toList()
        intent.putStringArrayListExtra(
            BackgroundStreamingService.EXTRA_LEASE_IDS,
            ArrayList(leases.map { it.id }),
        )
        intent.putStringArrayListExtra(
            BackgroundStreamingService.EXTRA_LEASE_KINDS,
            ArrayList(leases.map { it.kind }),
        )
        intent.putStringArrayListExtra(
            BackgroundStreamingService.EXTRA_MIC_LEASE_IDS,
            ArrayList(leases.filter { it.requiresMicrophone }.map { it.id }),
        )
        intent.putExtra(
            BackgroundStreamingService.EXTRA_STREAM_COUNT,
            leases.size,
        )
        intent.putExtra(
            BackgroundStreamingService.EXTRA_REQUIRES_MICROPHONE,
            leases.any { it.requiresMicrophone || it.isVoice },
        )
    }

    private fun notifyServiceFailure(e: Exception) {
        channel.invokeMethod("serviceFailed", mapOf(
            "error" to (e.message ?: "Unknown error"),
            "errorType" to e.javaClass.simpleName,
            "streamIds" to activeLeases.keys.toList(),
        ))
    }

    private fun startBackgroundMonitoring() {
        backgroundJob?.cancel()
        backgroundJob = scope.launch {
            while (activeLeases.isNotEmpty()) {
                // Check every 5 minutes - matches Flutter keepAlive interval.
                // This is a safety mechanism to clean up if Flutter fails to
                // call stopBackgroundExecution (e.g., crash recovery).
                delay(5 * 60 * 1000L)
                
                // Notify Dart side to check stream health
                channel.invokeMethod("checkStreams", null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        when (result) {
                            is Int -> {
                                if (result == 0) {
                                    activeLeases.clear()
                                    stopForegroundService()
                                } else if (!isActivityForeground && isServiceRequested) {
                                    keepAlive()
                                }
                            }
                        }
                    }
                    
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        println("BackgroundStreamingHandler: Error checking streams: $errorMessage")
                    }
                    
                    override fun notImplemented() {
                        println("BackgroundStreamingHandler: checkStreams method not implemented")
                    }
                })
            }
        }
    }

    private fun stopBackgroundMonitoring() {
        backgroundJob?.cancel()
        backgroundJob = null
    }

    private fun keepAlive() {
        if (activeLeases.isEmpty()) {
            stopForegroundService()
            return
        }

        // Keep-alive is only meaningful once the activity has actually moved
        // to the background. While foregrounded, track streams locally and let
        // normal in-app execution continue without a foreground service.
        if (isActivityForeground) {
            return
        }
        
        if (!isServiceRequested) {
            println("BackgroundStreamingHandler: Keep alive ignored; service is not running")
            return
        }
        
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.action = "KEEP_ALIVE"
            putLeases(serviceIntent)
            
            // Only update an already requested service. Starting a new service
            // from a background keep-alive path can crash on Android O+.
            context.startService(serviceIntent)
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to keep alive service: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Background Service"
            val descriptionText = "Background service for Conduit"
            val importance = NotificationManager.IMPORTANCE_LOW
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val existingChannel = notificationManager.getNotificationChannel(
                BackgroundStreamingService.CHANNEL_ID
            )

            if (existingChannel != null && existingChannel.importance == importance) {
                return
            }

            val canSafelyRecreate =
                existingChannel != null &&
                    existingChannel.importance == NotificationManager.IMPORTANCE_MIN &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    !existingChannel.hasUserSetImportance()

            // Only migrate the old IMPORTANCE_MIN channel when Android can tell
            // the user has not customized it. Otherwise preserve user settings.
            if (existingChannel != null && !canSafelyRecreate) {
                return
            }

            if (canSafelyRecreate) {
                notificationManager.deleteNotificationChannel(
                    BackgroundStreamingService.CHANNEL_ID
                )
            }

            val channel = NotificationChannel(
                BackgroundStreamingService.CHANNEL_ID,
                name,
                importance,
            ).apply {
                description = descriptionText
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }

            notificationManager.createNotificationChannel(channel)
        }
    }

    fun cleanup() {
        scope.cancel()
        stopBackgroundMonitoring()
        stopForegroundService()
        if (lifecycleObserverRegistered) {
            activity.lifecycle.removeObserver(activityLifecycleObserver)
            lifecycleObserverRegistered = false
        }
        
        // Unregister broadcast receiver
        if (receiverRegistered) {
            try {
                broadcastReceiver?.let {
                    context.unregisterReceiver(it)
                }
            } catch (e: Exception) {
                println("BackgroundStreamingHandler: Error unregistering receiver: ${e.message}")
            }
            broadcastReceiver = null
            receiverRegistered = false
        }
    }
}
