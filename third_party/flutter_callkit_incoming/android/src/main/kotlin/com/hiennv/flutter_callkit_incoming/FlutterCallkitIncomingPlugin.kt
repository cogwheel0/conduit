package com.hiennv.flutter_callkit_incoming

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import com.hiennv.flutter_callkit_incoming.Utils.Companion.reapCollection
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.lang.ref.WeakReference


/** FlutterCallkitIncomingPlugin */
@SuppressLint("LongLogTag")
class FlutterCallkitIncomingPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {

        const val EXTRA_CALLKIT_CALL_DATA = "EXTRA_CALLKIT_CALL_DATA"

        const val TAG = "FlutterCallkitIncomingPlugin"

        @SuppressLint("StaticFieldLeak")
        private lateinit var instance: FlutterCallkitIncomingPlugin

        fun getInstance(): FlutterCallkitIncomingPlugin? {
            if (hasInstance()) {
                return instance
            }
            return null
        }

        fun hasInstance(): Boolean {
            return ::instance.isInitialized
        }

        private val methodChannels = mutableMapOf<BinaryMessenger, MethodChannel>()
        private val eventChannels = mutableMapOf<BinaryMessenger, EventChannel>()
        private val eventHandlers = mutableMapOf<BinaryMessenger, EventCallbackHandler>()
        private val eventCallbacks = mutableListOf<WeakReference<CallkitEventCallback>>()

        fun sendEvent(event: String, body: Map<String, Any?>) {
            send(event, body)
        }

        fun sendEventCustom(event: String, body: Map<String, Any>) {
            send(event, body)
        }

        fun acceptCallHandleCallback(bundle: Bundle) {
            Handler(Looper.getMainLooper()).postDelayed({
                val extra = bundle.getSerializable(CallkitConstants.EXTRA_CALLKIT_EXTRA)
                methodChannels.values.forEach {
                    it.invokeMethod("acceptCallHandle", extra)
                }
            }, 750)
        }

        fun invokeFlutterCallback(data: Any) {
            Handler(Looper.getMainLooper()).postDelayed({
                methodChannels.values.forEach {
                    it.invokeMethod("invokeFlutter", data)
                }
            }, 750)
        }

        /**
         * Send event to Flutter UI if there are active handlers, otherwise send to background
         * executor if registered.
         */
        private fun send(event: String, body: Map<String, Any?>) {
            val uiHandlers = eventHandlers.values.filter { it.hasListener() }
            if (uiHandlers.isNotEmpty()) {
                Log.d(TAG, "Sending UI event: $event")
                uiHandlers.forEach { it.send(event, body) }
            } else if (CallkitBackgroundExecutor.registered) {
                Log.d(TAG, "Sending background event: $event (no UI handlers)")
                CallkitBackgroundExecutor.send(event, body)
            }
        }

        /**
         * Register a callback to receive call events (accept/decline) natively.
         * This allows other plugins/services to handle call events
         * even when Flutter engine is terminated.
         */
        fun registerEventCallback(callback: CallkitEventCallback) {
            eventCallbacks.add(WeakReference(callback))
        }

        /**
         * Unregister an event callback.
         */
        fun unregisterEventCallback(callback: CallkitEventCallback) {
            eventCallbacks.removeAll { it.get() == callback || it.get() == null }
        }

        /**
         * Notify all registered event callbacks.
         * Called internally when a call event occurs.
         */
        internal fun notifyEventCallbacks(event: CallkitEventCallback.CallEvent, callData: android.os.Bundle) {
            eventCallbacks.reapCollection().forEach { callbackRef ->
                callbackRef.get()?.onCallEvent(event, callData)
            }
        }


        fun sharePluginWithRegister(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
            initSharedInstance(
                flutterPluginBinding.applicationContext,
                flutterPluginBinding.binaryMessenger
            )
        }

        fun initSharedInstance(context: Context, binaryMessenger: BinaryMessenger) {
            if (!::instance.isInitialized) {
                instance = FlutterCallkitIncomingPlugin()
            }
            // Restore instance fields that may have been nulled during a previous
            // detach. The static `instance` survives across FlutterEngine teardown
            // when the host process is kept alive (e.g. foreground services),
            // so `onAttachedToEngine` must refresh these fields every time;
            // otherwise background-isolate calls end up as silent no-ops.
            if (instance.callkitSoundPlayerManager == null) {
                instance.callkitSoundPlayerManager = CallkitSoundPlayerManager(context)
            }
            if (instance.callkitNotificationManager == null) {
                instance.callkitNotificationManager = CallkitNotificationManager(context, instance.callkitSoundPlayerManager)
            }
            if (instance.context == null) {
                instance.context = context
            } else {
                // Re-initialize managers if they were destroyed but instance still exists
                if (instance.callkitNotificationManager == null) {
                    instance.callkitSoundPlayerManager = CallkitSoundPlayerManager(context)
                    instance.callkitNotificationManager = CallkitNotificationManager(context, instance.callkitSoundPlayerManager)
                }
            }

            val channel = MethodChannel(binaryMessenger, "flutter_callkit_incoming")
            methodChannels[binaryMessenger] = channel
            channel.setMethodCallHandler(instance)

            val events = EventChannel(binaryMessenger, "flutter_callkit_incoming_events")
            eventChannels[binaryMessenger] = events
            val handler = EventCallbackHandler()
            eventHandlers[binaryMessenger] = handler
            events.setStreamHandler(handler)

        }

    }

    /// The MethodChannel that will the communication between Flutter and native Android
    ///
    /// This local reference serves to register the plugin with the Flutter Engine and unregister it
    /// when the Flutter Engine is detached from the Activity
    private var activity: Activity? = null
    private var context: Context? = null
    private var callkitNotificationManager: CallkitNotificationManager? = null
    private var callkitSoundPlayerManager: CallkitSoundPlayerManager? = null

    fun getCallkitNotificationManager(): CallkitNotificationManager? {
        return callkitNotificationManager
    }

    fun getCallkitSoundPlayerManager(): CallkitSoundPlayerManager? {
        return callkitSoundPlayerManager
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        sharePluginWithRegister(flutterPluginBinding)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            InAppCallManager(flutterPluginBinding.applicationContext).registerPhoneAccount()
        }
    }

    public fun showIncomingNotification(data: Data) {
        data.from = "notification"
        //send BroadcastReceiver
        context?.sendBroadcast(
            CallkitIncomingBroadcastReceiver.getIntentIncoming(
                requireNotNull(context),
                data.toBundle()
            )
        )
    }

    public fun showMissCallNotification(data: Data) {
        callkitNotificationManager?.showMissCallNotification(data.toBundle())
    }

    public fun startCall(data: Data) {
        context?.sendBroadcast(
            CallkitIncomingBroadcastReceiver.getIntentStart(
                requireNotNull(context),
                data.toBundle()
            )
        )
    }

    public fun endCall(data: Data) {
        context?.sendBroadcast(
            CallkitIncomingBroadcastReceiver.getIntentEnded(
                requireNotNull(context),
                data.toBundle()
            )
        )
    }

    public fun endAllCalls() {
        val calls = getDataActiveCalls(context)
        calls.forEach {
            context?.sendBroadcast(
                CallkitIncomingBroadcastReceiver.getIntentEnded(
                    requireNotNull(context),
                    it.toBundle()
                )
            )
        }
        removeAllCalls(context)
    }

    fun sendEventCustom(body: Map<String, Any>) {
        send(CallkitConstants.ACTION_CALL_CUSTOM, body)
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        // A MethodChannel result may be submitted exactly once. Wrapping it means a
        // throw after a successful reply cannot turn into "Reply already submitted".
        val reply = SingleReply(result)
        try {
            when (call.method) {
                "registerBackgroundHandler" -> {
                    val args = call.arguments as Map<*, *>
                    val pluginHandle = (args["pluginHandle"] as Number).toLong()
                    val userHandle = (args["userHandle"] as Number).toLong()
                    addBackgroundCallback(context, pluginHandle, userHandle)
                    CallkitBackgroundExecutor.start(requireNotNull(context), pluginHandle)
                    reply.success(null)
                }

                "getBackgroundHandler" -> {
                    val handle = getUserCallback(context)
                    reply.success(handle)
                }

                "setAcceptCallHandle" -> {
                    val args = call.arguments as? List<*>
                    if (args != null && args.size >= 2) {
                        val handle = args[0] as? Int ?: 0
                        val key = args[1] as? String ?: ""
                        saveHandle(context, key, handle)
                    }
                    reply.success(null)
                }

                "showCallkitIncoming" -> {
                    val data = Data(call.arguments() ?: HashMap())
                    data.from = "notification"
                    //send BroadcastReceiver
                    context?.sendBroadcast(
                        CallkitIncomingBroadcastReceiver.getIntentIncoming(
                            requireNotNull(context),
                            data.toBundle()
                        )
                    )

                    reply.success(true)
                }

                "showCallkitIncomingSilently" -> {
                    val data = Data(call.arguments() ?: HashMap())
                    data.from = "notification"

                    reply.success(true)
                }

                "showMissCallNotification" -> {
                    val data = Data(call.arguments() ?: HashMap())
                    data.from = "notification"
                    callkitNotificationManager?.showMissCallNotification(data.toBundle())
                    reply.success(true)
                }

                "startCall" -> {
                    val data = Data(call.arguments() ?: HashMap())
                    context?.sendBroadcast(
                        CallkitIncomingBroadcastReceiver.getIntentStart(
                            requireNotNull(context),
                            data.toBundle()
                        )
                    )

                    reply.success(true)
                }

                "muteCall" -> {
                    val map = buildMap {
                        val args = call.arguments
                        if (args is Map<*, *>) {
                            putAll(args as Map<String, Any>)
                        }
                    }
                    sendEvent(CallkitConstants.ACTION_CALL_TOGGLE_MUTE, map)

                    reply.success(true)
                }

                "holdCall" -> {
                    val map = buildMap {
                        val args = call.arguments
                        if (args is Map<*, *>) {
                            putAll(args as Map<String, Any>)
                        }
                    }
                    sendEvent(CallkitConstants.ACTION_CALL_TOGGLE_HOLD, map)

                    reply.success(true)
                }

                "isMuted" -> {
                    reply.success(true)
                }

                "endCall" -> {
                    val calls = getDataActiveCalls(context)
                    val data = Data(call.arguments() ?: HashMap())
                    val currentCall = calls.firstOrNull { it.id == data.id }
                    if (currentCall != null && context != null) {
                        if(currentCall.isAccepted) {
                            context?.sendBroadcast(
                                CallkitIncomingBroadcastReceiver.getIntentEnded(
                                    requireNotNull(context),
                                    currentCall.toBundle()
                                )
                            )
                        }else {
                            context?.sendBroadcast(
                                CallkitIncomingBroadcastReceiver.getIntentDecline(
                                    requireNotNull(context),
                                    currentCall.toBundle()
                                )
                            )
                        }
                    }
                    reply.success(true)
                }

                "callConnected" -> {
                    val calls = getDataActiveCalls(context)
                    val data = Data(call.arguments() ?: HashMap())
                    val currentCall = calls.firstOrNull { it.id == data.id }
                    if (currentCall != null && context != null) {
                        context?.sendBroadcast(
                            CallkitIncomingBroadcastReceiver.getIntentConnected(
                                requireNotNull(context),
                                currentCall.toBundle()
                            )
                        )
                    }
                    reply.success(true)
                }

                "endAllCalls" -> {
                    val calls = getDataActiveCalls(context)
                    calls.forEach {
                        if (it.isAccepted) {
                            context?.sendBroadcast(
                                CallkitIncomingBroadcastReceiver.getIntentEnded(
                                    requireNotNull(context),
                                    it.toBundle()
                                )
                            )
                        } else {
                            context?.sendBroadcast(
                                CallkitIncomingBroadcastReceiver.getIntentDecline(
                                    requireNotNull(context),
                                    it.toBundle()
                                )
                            )
                        }
                    }
                    removeAllCalls(context)
                    reply.success(true)
                }

                "activeCalls" -> {
                    reply.success(getDataActiveCallsForFlutter(context))
                }

                "getDevicePushTokenVoIP" -> {
                    reply.success("")
                }

                "silenceEvents" -> {
                    val silence = call.arguments as? Boolean ?: false
                    CallkitIncomingBroadcastReceiver.silenceEvents = silence
                    reply.success(true)
                }

                "requestNotificationPermission" -> {
                    val map = buildMap {
                        val args = call.arguments
                        if (args is Map<*, *>) {
                            putAll(args as Map<String, Any>)
                        }
                    }
                    callkitNotificationManager?.requestNotificationPermission(activity, map)
                    reply.success(true)
                }

                "requestFullIntentPermission" -> {
                    callkitNotificationManager?.requestFullIntentPermission(activity)
                    reply.success(true)
                }

                "canUseFullScreenIntent" -> {
                    reply.success(callkitNotificationManager?.canUseFullScreenIntent() ?: true)
                }

                // EDIT - clear the incoming notification/ring (after accept/decline/timeout)
                "hideCallkitIncoming" -> {
                    val data = Data(call.arguments() ?: HashMap())
                    callkitSoundPlayerManager?.stop()
                    callkitNotificationManager?.clearIncomingNotification(data.toBundle(), false)
                    reply.success(true)
                }

                "endNativeSubsystemOnly" -> {
                    reply.success(true)
                }

                "setAudioRoute" -> {
                    reply.success(true)
                }

                else -> {
                    // Without this an unknown method returns without submitting a
                    // result, leaving the Dart Future pending forever.
                    reply.notImplemented()
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "onMethodCall(${call.method}) failed", error)
            reply.error("error", error.message, "")
        }
    }

    /**
     * Forwards at most one reply to the underlying [Result]; later calls are dropped.
     */
    private class SingleReply(private val delegate: Result) : Result {
        private var replied = false

        override fun success(value: Any?) {
            if (replied) return
            replied = true
            delegate.success(value)
        }

        override fun error(code: String, message: String?, details: Any?) {
            if (replied) return
            replied = true
            delegate.error(code, message, details)
        }

        override fun notImplemented() {
            if (replied) return
            replied = true
            delegate.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannels.remove(binding.binaryMessenger)?.setMethodCallHandler(null)
        eventChannels.remove(binding.binaryMessenger)?.setStreamHandler(null)
        eventHandlers.remove(binding.binaryMessenger)

        // Only destroy and null the shared managers when the LAST engine detaches.
        // When multiple engines are attached (e.g. main UI engine + FCM background
        // isolate engine), tearing down the main engine must not pull the managers
        // out from under the background isolate that still needs them.
        if (methodChannels.isEmpty() && eventChannels.isEmpty()) {
            instance.callkitSoundPlayerManager?.destroy()
            instance.callkitNotificationManager?.destroy()
            instance.callkitSoundPlayerManager = null
            instance.callkitNotificationManager = null
        }
        Log.d(TAG, "onDetachedFromEngine")
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        instance.context = binding.activity.applicationContext
        instance.activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        instance.context = binding.activity.applicationContext
        instance.activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        // Keep instance.context alive. It is the applicationContext, shared by
        // every engine attachment and safe to hold for the lifetime of the JVM.
        // Nulling it here would break background-isolate method channel calls
        // (showCallkitIncoming relies on `context?.sendBroadcast(...)`) whenever
        // the activity is destroyed while a cached background engine keeps the
        // static `instance` alive.
        instance.activity = null
    }

    class EventCallbackHandler : EventChannel.StreamHandler {

        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        fun hasListener(): Boolean = eventSink != null

        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
            eventSink = sink
        }

        fun send(event: String, body: Map<String, Any?>) {
            val data = mapOf(
                "event" to event,
                "body" to body
            )
            Handler(Looper.getMainLooper()).post {
                eventSink?.success(data)
            }
        }

        override fun onCancel(arguments: Any?) {
            eventSink = null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        instance.callkitNotificationManager?.onRequestPermissionsResult(
            instance.activity,
            requestCode,
            grantResults
        )
        return true
    }


}
