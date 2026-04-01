package app.cogwheel.qonduit

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
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*

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
 * - For socket keepalive: Runs with dataSync type, NO wake lock (CPU can sleep between pings)
 *
 * Android 14+ (UPSIDE_DOWN_CAKE) limitation:
 * - dataSync foreground services are limited to 6 hours
 * - We stop at 5 hours to provide a 1-hour buffer and notify the Flutter layer
 */
class BackgroundStreamingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var activeStreamCount = 0
    private var isForeground = false
    private var currentForegroundType: Int = 0
    private var foregroundStartTime: Long = 0

    companion object {
        const val CHANNEL_ID = "qonduit_streaming_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "START_STREAMING"
        const val ACTION_STOP = "STOP_STREAMING"
        const val EXTRA_REQUIRES_MICROPHONE = "requiresMicrophone"
        const val EXTRA_STREAM_COUNT = "streamCount"
        
        const val ACTION_TIME_LIMIT_APPROACHING = "app.cogwheel.qonduit.TIME_LIMIT_APPROACHING"
        const val ACTION_MIC_PERMISSION_FALLBACK = "app.cogwheel.qonduit.MIC_PERMISSION_FALLBACK"
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
                // Channel should already exist (created in QonduitApplication)
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
                    .setContentTitle("Qonduit")
                    .setSmallIcon(R.mipmap.ic_launcher)
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
        val incomingStreamCount =
            intent?.getIntExtra(EXTRA_STREAM_COUNT, 0) ?: 0
        activeStreamCount = incomingStreamCount

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
                true
            }

            if (!enteredForeground) {
                stopSelf()
                return START_NOT_STICKY
            }

            // If no streams are active after entering foreground, shut down to
            // avoid lingering foreground instances that could trigger
            // DidNotStopInTime exceptions.
            if (activeStreamCount <= 0) {
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
                if (activeStreamCount > 0) {
                    acquireWakeLock()
                    println("BackgroundStreamingService: Started foreground service")
                } else {
                    println("BackgroundStreamingService: No active streams; skipping wake lock")
                }
            }
        }

        return START_STICKY
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
        val intent = Intent("app.cogwheel.qonduit.FOREGROUND_SERVICE_FAILED")
        intent.putExtra("error", e.message ?: "Unknown error")
        intent.putExtra("errorType", e.javaClass.simpleName)
        sendBroadcast(intent)
    }

    private fun updateForegroundType(notification: Notification, type: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            startForeground(NOTIFICATION_ID, notification, type)
            currentForegroundType = type
        } catch (e: SecurityException) {
            println("BackgroundStreamingService: Unable to update foreground type: ${e.message}")
        }
    }

    private fun resolveForegroundServiceType(intent: Intent?): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0

        val requiresMicrophone = intent?.getBooleanExtra(EXTRA_REQUIRES_MICROPHONE, false) ?: false
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
            .setContentTitle("Qonduit")
            .setContentText("Background service active")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_MIN)
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
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Background service for Qonduit"
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
    
    /**
     * Acquires a wake lock to prevent CPU sleep during active streaming.
     * 
     * Timeout is set to 7 minutes (420 seconds) to cover the 5-minute keepAlive
     * interval with a 2-minute buffer. This ensures continuous wake lock coverage
     * even if the keepAlive timer drifts or is delayed by CPU throttling.
     * 
     * Note: Android Play Console may flag wake locks > 1 minute as "excessive",
     * but continuous CPU availability is required for reliable streaming.
     * The alternative (60-second timeout with 5-minute refresh) creates 4-minute
     * gaps where the CPU can sleep, causing streams to stall.
     * 
     * Uses setReferenceCounted(false) for deterministic single-holder semantics,
     * with manual timeout handling via Handler to ensure proper cleanup.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Qonduit::StreamingWakeLock"
        ).apply {
            // Disable reference counting for deterministic single-holder behavior
            // This prevents accumulation if acquireWakeLock is called multiple times
            setReferenceCounted(false)
            acquire()
        }
        
        // Schedule manual timeout release (7 minutes)
        // This replaces the acquire(timeout) approach which conflicts with setReferenceCounted(false)
        wakeLockTimeoutRunnable?.let { wakeLockHandler.removeCallbacks(it) }
        wakeLockTimeoutRunnable = Runnable {
            println("BackgroundStreamingService: Wake lock timeout reached, releasing")
            releaseWakeLock()
        }
        wakeLockHandler.postDelayed(wakeLockTimeoutRunnable!!, 7 * 60 * 1000L)
        
        println("BackgroundStreamingService: Wake lock acquired (7min manual timeout)")
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
        
        // activeStreamCount reflects user-visible streams (excludes socket-keepalive)
        if (activeStreamCount > 0) {
            // Refresh wake lock to maintain CPU availability for actual streaming.
            // Wake lock has 7-minute timeout, keepAlive is called every 5 minutes,
            // ensuring continuous coverage with 2-minute overlap buffer.
            // Note: Foreground services prevent process termination but NOT CPU sleep.
            releaseWakeLock()
            acquireWakeLock()
            println("BackgroundStreamingService: Keep alive - wake lock refreshed, ${activeStreamCount} active streams")
        } else {
            // No active streams - just socket keepalive running.
            // Foreground service keeps app alive; no wakelock needed.
            releaseWakeLock()
            println("BackgroundStreamingService: Keep alive (background task, no wakelock)")
        }
    }
    
    private fun stopStreaming() {
        println("BackgroundStreamingService: Stopping service...")
        activeStreamCount = 0
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
        activeStreamCount = 0
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

    private val activeStreams = mutableSetOf<String>()
    private val streamsRequiringMic = mutableSetOf<String>()
    private var backgroundJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var broadcastReceiver: android.content.BroadcastReceiver? = null
    private var receiverRegistered = false
    
    companion object {
        private const val CHANNEL_NAME = "qonduit/background_streaming"
    }

    fun setup(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        context = activity.applicationContext
        
        createNotificationChannel()
        setupBroadcastReceiver()
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
                    "app.cogwheel.qonduit.FOREGROUND_SERVICE_FAILED" -> {
                        val error = intent.getStringExtra("error") ?: "Unknown error"
                        val errorType = intent.getStringExtra("errorType") ?: "Exception"
                        
                        println("BackgroundStreamingHandler: Service failure received: $errorType - $error")
                        
                        // Notify Flutter about the service failure
                        channel.invokeMethod("serviceFailed", mapOf(
                            "error" to error,
                            "errorType" to errorType,
                            "streamIds" to activeStreams.toList()
                        ))
                        
                        // Clear active streams since service failed
                        activeStreams.clear()
                        streamsRequiringMic.clear()
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
            addAction("app.cogwheel.qonduit.FOREGROUND_SERVICE_FAILED")
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
                    startBackgroundExecution(streamIds, requiresMic)
                    result.success(null)
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
                val streamCount = call.argument<Int>("streamCount")
                keepAlive(streamCount)
                result.success(null)
            }
            
            "checkNotificationPermission" -> {
                result.success(hasNotificationPermission())
            }
            
            "getActiveStreamCount" -> {
                // Return count for Flutter-native state reconciliation
                result.success(activeStreams.size)
            }
            
            "stopAllBackgroundExecution" -> {
                // Stop all streams (used for reconciliation when orphaned service detected)
                val allStreams = activeStreams.toList()
                stopBackgroundExecution(allStreams)
                result.success(null)
            }
            
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun startBackgroundExecution(streamIds: List<String>, requiresMic: Boolean) {
        activeStreams.addAll(streamIds)
        streamsRequiringMic.retainAll(activeStreams)
        if (requiresMic) {
            streamsRequiringMic.addAll(streamIds)
        }

        if (activeStreams.isNotEmpty()) {
            startForegroundService()
            startBackgroundMonitoring()
        }
    }

    private fun stopBackgroundExecution(streamIds: List<String>) {
        activeStreams.removeAll(streamIds.toSet())
        streamsRequiringMic.removeAll(streamIds.toSet())

        if (activeStreams.isEmpty()) {
            stopForegroundService()
            stopBackgroundMonitoring()
        }
    }

    private fun startForegroundService() {
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_STREAM_COUNT,
                activeStreams.size,
            )
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_REQUIRES_MICROPHONE,
                streamsRequiringMic.isNotEmpty(),
            )
            serviceIntent.action = BackgroundStreamingService.ACTION_START

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to start foreground service: ${e.message}")
            // Clear active streams as we couldn't start the service
            activeStreams.clear()
            streamsRequiringMic.clear()
        }
    }

    private fun stopForegroundService() {
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.action = BackgroundStreamingService.ACTION_STOP
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_STREAM_COUNT,
                activeStreams.size,
            )
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_REQUIRES_MICROPHONE,
                streamsRequiringMic.isNotEmpty(),
            )

            // IMPORTANT: Avoid stopService() here.
            //
            // If Android has already received a startForegroundService() request,
            // calling stopService() in a tight start/stop race can destroy the
            // instance before that start request is fully satisfied, which can
            // trigger ForegroundServiceDidNotStartInTimeException.
            //
            // By sending an explicit STOP command through startService(), the
            // service lifecycle can complete onCreate/onStartCommand safely, then
            // stop itself via stopStreaming().
            context.startService(serviceIntent)
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to stop foreground service: ${e.message}")
        }
    }

    private fun startBackgroundMonitoring() {
        backgroundJob?.cancel()
        backgroundJob = scope.launch {
            while (activeStreams.isNotEmpty()) {
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
                                    activeStreams.clear()
                                    stopForegroundService()
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

    private fun keepAlive(userVisibleStreamCount: Int? = null) {
        // Check local activeStreams to decide if service should run
        // (includes socket-keepalive and other background tasks)
        if (activeStreams.isEmpty()) {
            stopForegroundService()
            return
        }
        
        // Use Flutter's user-visible stream count for logging (excludes socket-keepalive)
        // Fall back to local count if not provided
        val streamCount = userVisibleStreamCount ?: activeStreams.size
        
        try {
            val serviceIntent = Intent(context, BackgroundStreamingService::class.java)
            serviceIntent.action = "KEEP_ALIVE"
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_STREAM_COUNT,
                streamCount,
            )
            serviceIntent.putExtra(
                BackgroundStreamingService.EXTRA_REQUIRES_MICROPHONE,
                streamsRequiringMic.isNotEmpty(),
            )
            
            // Use startService (not startForegroundService) for keep-alive pings
            // to avoid ForegroundServiceStartNotAllowedException on Android 14+
            context.startService(serviceIntent)
        } catch (e: Exception) {
            println("BackgroundStreamingHandler: Failed to keep alive service: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Background Service"
            val descriptionText = "Background service for Qonduit"
            val importance = NotificationManager.IMPORTANCE_MIN
            val channel = NotificationChannel(BackgroundStreamingService.CHANNEL_ID, name, importance).apply {
                description = descriptionText
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }

            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    fun cleanup() {
        scope.cancel()
        stopBackgroundMonitoring()
        stopForegroundService()
        
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
