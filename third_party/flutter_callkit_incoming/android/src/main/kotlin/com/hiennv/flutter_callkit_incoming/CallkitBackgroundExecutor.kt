package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation

object CallkitBackgroundExecutor {
    private const val TAG = "CallkitBGExecutor"
    private const val CHANNEL = "flutter_callkit_incoming_background"

    @Volatile
    private var backgroundFlutterEngine: FlutterEngine? = null

    private var backgroundChannel: MethodChannel? = null

    val registered: Boolean
        get() = backgroundFlutterEngine != null

    fun start(context: Context, pluginCallbackHandle: Long) {
        if (backgroundFlutterEngine != null) {
            Log.d(TAG, "Background engine already running")
            return
        }

        val appCtx = context.applicationContext

        val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(appCtx)
        loader.ensureInitializationComplete(appCtx, null)

        backgroundFlutterEngine = FlutterEngine(appCtx)

        val callbackInfo =
            FlutterCallbackInformation.lookupCallbackInformation(pluginCallbackHandle)

        val args = DartExecutor.DartCallback(
            appCtx.assets,
            loader.findAppBundlePath(),
            callbackInfo
        )

        backgroundFlutterEngine!!.dartExecutor.executeDartCallback(args)
        backgroundChannel = MethodChannel(
            backgroundFlutterEngine!!.dartExecutor.binaryMessenger,
            CHANNEL
        )

        Log.d(TAG, "Background engine started")
    }

    fun send(event: String, body: Map<String, Any?>) {
        if (backgroundFlutterEngine == null) {
            Log.e(TAG, "Background engine not started, cannot send event: $event")
            return
        }
        backgroundChannel!!.invokeMethod(event, body)
    }
}
