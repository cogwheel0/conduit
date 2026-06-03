package es.antonborri.home_widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Minimal Android compatibility implementation for home_widget 0.9.2.
 *
 * The published package still declares this plugin class for Android, but the
 * Android sources are absent. Keep the channel behavior used by Conduit here so
 * Flutter's generated registrant can compile and widget launches keep working.
 */
class HomeWidgetPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private var appContext: Context? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        handleLaunchIntent(binding.activity.intent, initial = true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        return handleLaunchIntent(intent, initial = false)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveWidgetData" -> result.success(saveWidgetData(call))
            "getWidgetData" -> result.success(getWidgetData(call))
            "updateWidget" -> updateWidget(call, result)
            "isRequestPinWidgetSupported" -> result.success(isRequestPinWidgetSupported())
            "requestPinWidget" -> requestPinWidget(call, result)
            "setAppGroupId" -> result.success(true)
            "initiallyLaunchedFromHomeWidget" -> {
                val uri = initialLaunchUri
                initialLaunchUri = null
                result.success(uri)
            }
            "initiallyLaunchedFromHomeWidgetConfigure" -> result.success(null)
            "finishHomeWidgetConfigure" -> result.success(null)
            "registerBackgroundCallback" -> result.success(false)
            "getInstalledWidgets" -> result.success(getInstalledWidgets())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        pendingLaunchUri?.let {
            events?.success(it)
            pendingLaunchUri = null
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun handleLaunchIntent(intent: Intent?, initial: Boolean): Boolean {
        if (intent == null || intent.action != HOME_WIDGET_LAUNCH_ACTION) {
            return false
        }
        if (initial && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            return false
        }

        val uri = intent.data?.toString()?.takeIf { it.isNotBlank() } ?: return false
        if (initial) {
            initialLaunchUri = uri
        } else {
            emitLaunchUri(uri)
        }
        return true
    }

    private fun emitLaunchUri(uri: String) {
        val sink = eventSink
        if (sink == null) {
            pendingLaunchUri = uri
        } else {
            sink.success(uri)
        }
    }

    private fun saveWidgetData(call: MethodCall): Boolean {
        val context = appContext ?: return false
        val id = call.argument<String>("id") ?: return false
        val data = call.argument<Any?>("data")
        val editor = context.widgetPreferences().edit()

        when (data) {
            null -> editor.remove(id)
            is Boolean -> editor.putBoolean(id, data)
            is String -> editor.putString(id, data)
            is Int -> editor.putInt(id, data)
            is Long -> editor.putLong(id, data)
            is Float -> editor.putFloat(id, data)
            is Double -> editor.putFloat(id, data.toFloat())
            else -> editor.putString(id, data.toString())
        }

        return editor.commit()
    }

    private fun getWidgetData(call: MethodCall): Any? {
        val context = appContext ?: return call.argument<Any?>("defaultValue")
        val id = call.argument<String>("id") ?: return call.argument<Any?>("defaultValue")
        val preferences = context.widgetPreferences()
        if (!preferences.contains(id)) {
            return call.argument<Any?>("defaultValue")
        }

        return preferences.all[id]
    }

    private fun updateWidget(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.success(false)
            return
        }

        val component = findProviderComponent(context, providerNameFromCall(call))
        if (component == null) {
            result.success(false)
            return
        }

        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(component)
        if (ids.isEmpty()) {
            result.success(false)
            return
        }

        val updateIntent = Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
            setComponent(component)
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        }
        context.sendBroadcast(updateIntent)
        result.success(true)
    }

    private fun isRequestPinWidgetSupported(): Boolean {
        val context = appContext ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        return AppWidgetManager.getInstance(context).isRequestPinAppWidgetSupported
    }

    private fun requestPinWidget(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null)
            return
        }

        val component = findProviderComponent(context, providerNameFromCall(call))
        if (component == null) {
            result.success(null)
            return
        }

        AppWidgetManager.getInstance(context).requestPinAppWidget(component, null, null)
        result.success(null)
    }

    private fun getInstalledWidgets(): List<Map<String, Any?>> {
        val context = appContext ?: return emptyList()
        val manager = AppWidgetManager.getInstance(context)
        return appWidgetReceivers(context).flatMap { receiver ->
            val info = receiver.activityInfo ?: return@flatMap emptyList()
            val component = ComponentName(info.packageName, info.name)
            manager.getAppWidgetIds(component).map { widgetId ->
                mapOf(
                    "widgetId" to widgetId,
                    "androidClassName" to info.name,
                    "label" to receiver.loadLabel(context.packageManager)?.toString(),
                )
            }
        }
    }

    private fun providerNameFromCall(call: MethodCall): String? {
        return call.argument<String>("qualifiedAndroidName")
            ?: call.argument<String>("android")
            ?: call.argument<String>("name")
    }

    private fun findProviderComponent(context: Context, requestedName: String?): ComponentName? {
        if (requestedName.isNullOrBlank()) {
            return appWidgetReceivers(context).firstNotNullOfOrNull { receiver ->
                receiver.activityInfo?.let { ComponentName(it.packageName, it.name) }
            }
        }

        appWidgetReceivers(context).firstOrNull { receiver ->
            val className = receiver.activityInfo?.name ?: return@firstOrNull false
            className == requestedName ||
                className.endsWith(".$requestedName") ||
                className.substringAfterLast('.') == requestedName
        }?.activityInfo?.let {
            return ComponentName(it.packageName, it.name)
        }

        val packageManager = context.packageManager
        val launchClassPackage = packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.component
            ?.className
            ?.substringBeforeLast('.')

        val candidates = buildList {
            add(requestedName)
            if (!requestedName.contains('.')) {
                add("${context.packageName}.$requestedName")
                launchClassPackage?.let { add("$it.$requestedName") }
            }
        }

        return candidates.firstNotNullOfOrNull { className ->
            runCatching {
                val providerClass = Class.forName(className)
                ComponentName(context, providerClass)
            }.getOrNull()
        }
    }

    private fun appWidgetReceivers(context: Context): List<ResolveInfo> {
        val intent = Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            .setPackage(context.packageName)
        val packageManager = context.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryBroadcastReceivers(
                intent,
                PackageManager.ResolveInfoFlags.of(PackageManager.GET_META_DATA.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryBroadcastReceivers(intent, PackageManager.GET_META_DATA)
        }
    }

    private fun Context.widgetPreferences() =
        getSharedPreferences(WIDGET_PREFERENCES_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val METHOD_CHANNEL = "home_widget"
        private const val EVENT_CHANNEL = "home_widget/updates"
        private const val HOME_WIDGET_LAUNCH_ACTION = "es.antonborri.home_widget.action.LAUNCH"
        private const val WIDGET_PREFERENCES_NAME = "HomeWidgetPreferences"

        private var initialLaunchUri: String? = null
        private var pendingLaunchUri: String? = null
    }
}
