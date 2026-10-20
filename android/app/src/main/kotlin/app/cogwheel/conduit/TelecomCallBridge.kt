package app.cogwheel.conduit

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telecom.CallAudioState
import androidx.annotation.RequiresApi
import com.hiennv.flutter_callkit_incoming.CallkitConnection
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The [CallAudioState] route to ask Telecom for so the call is on the
 * loudspeaker, or off it, when it is on [route] now; null when it already is.
 *
 * Off the loudspeaker, the call goes to Bluetooth when Telecom has it, as the
 * coordinator's own earpiece route prefers, and to the wired headset or
 * earpiece otherwise. A call already off the loudspeaker stays on the headset,
 * Bluetooth or earpiece Telecom picked.
 */
internal fun telecomAudioRouteFor(speaker: Boolean, route: Int?, supportedRoutes: Int): Int? =
    when {
        speaker -> CallAudioState.ROUTE_SPEAKER.takeIf { it != route }
        route != CallAudioState.ROUTE_SPEAKER -> null
        (supportedRoutes and CallAudioState.ROUTE_BLUETOOTH) != 0 -> CallAudioState.ROUTE_BLUETOOTH
        else -> CallAudioState.ROUTE_WIRED_OR_EARPIECE
    }

/**
 * Works with the Telecom call flutter_callkit_incoming hosts a voice call in.
 *
 * The plugin places Conduit's outgoing calls in Telecom as self-managed calls,
 * a moment after `startCall` returns: the call's Connection only exists once
 * Telecom has bound the plugin's ConnectionService. Two things go wrong
 * without waiting for it (issue #846):
 *
 * - `setCallConnected` arriving before the Connection is dropped by the plugin,
 *   so the call stays DIALING. Telecom ends calls stuck there two minutes in,
 *   and a dialing call blocks the user's own phone calls until it does.
 * - While the call is in Telecom, Telecom owns the audio mode as a privileged
 *   client, and AudioService ignores this app's own setCommunicationDevice and
 *   setSpeakerphoneOn requests. The Connection is the one route request
 *   Telecom takes, so the call coordinator asks it first and then reads the
 *   route back from AudioManager as before.
 */
class TelecomCallBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.applicationContext
        .getSystemService(Context.AUDIO_SERVICE) as AudioManager

    // The call the last lookup settled for, found or given up on. Only the
    // first lookups for a call wait for Telecom to create its connection.
    private var lookedUpCallId: String? = null

    fun setup(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val callId = call.argument<String>("callId")
        when (call.method) {
            "awaitConnection" -> {
                if (callId == null) {
                    result.error("INVALID_ARGS", "callId is required", null)
                    return
                }
                // flutter_callkit_incoming only places calls in Telecom from
                // Android 8, which is also when Connection.setAudioRoute arrived.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    result.success(false)
                    return
                }
                findConnection(callId, SystemClock.uptimeMillis() + CONNECTED_WAIT_MS) {
                    result.success(it != null)
                }
            }
            "routeAudio" -> {
                val speaker = call.argument<Boolean>("speaker")
                if (callId == null || speaker == null) {
                    result.error("INVALID_ARGS", "callId and speaker are required", null)
                    return
                }
                // Answers null when Telecom does not host the call (it never
                // did, or it has dropped it), so the caller's own route
                // requests are the ones that count.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    result.success(null)
                    return
                }
                routeAudio(callId, speaker, result)
            }
            else -> result.notImplemented()
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun routeAudio(callId: String, speaker: Boolean, result: MethodChannel.Result) {
        val wait = if (lookedUpCallId == callId) 0L else ROUTE_CONNECTION_WAIT_MS
        findConnection(callId, SystemClock.uptimeMillis() + wait) { connection ->
            if (connection == null) {
                result.success(null)
            } else {
                routeAudio(connection, speaker, result)
            }
        }
    }

    /** Calls [found] with the call's connection once Telecom has created it. */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun findConnection(
        callId: String,
        deadline: Long,
        found: (CallkitConnection?) -> Unit,
    ) {
        val connection = CallkitConnection.find(callId)
        if (connection != null || SystemClock.uptimeMillis() >= deadline) {
            lookedUpCallId = callId
            found(connection)
            return
        }
        main.postDelayed({ findConnection(callId, deadline, found) }, POLL_INTERVAL_MS)
    }

    /**
     * Asks Telecom to play the call on the loudspeaker, or off it, and answers
     * once AudioManager shows the route or the wait runs out.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    @Suppress("DEPRECATION")
    private fun routeAudio(
        connection: CallkitConnection,
        speaker: Boolean,
        result: MethodChannel.Result,
    ) {
        // Deprecated from Android 14 in favour of call endpoints, which this
        // plugin's connection does not track; Telecom still honours both.
        val audioState: CallAudioState? = connection.callAudioState
        telecomAudioRouteFor(
            speaker,
            audioState?.route,
            audioState?.supportedRouteMask ?: 0,
        )?.let { connection.setAudioRoute(it) }
        awaitRoute(speaker, SystemClock.uptimeMillis() + ROUTE_SETTLE_MS, result)
    }

    /** Telecom applies a route change asynchronously; wait until it lands. */
    private fun awaitRoute(speaker: Boolean, deadline: Long, result: MethodChannel.Result) {
        val loudspeaker = isOnLoudspeaker()
        if (loudspeaker == speaker || SystemClock.uptimeMillis() >= deadline) {
            result.success(mapOf("loudspeaker" to loudspeaker))
            return
        }
        main.postDelayed({ awaitRoute(speaker, deadline, result) }, POLL_INTERVAL_MS)
    }

    /** The same read-back the call coordinator makes through audio_session. */
    private fun isOnLoudspeaker(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = audioManager.communicationDevice
            if (device != null) {
                return device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
        }
        @Suppress("DEPRECATION")
        return audioManager.isSpeakerphoneOn
    }

    companion object {
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/telecom_call"
        private const val CONNECTED_WAIT_MS = 5000L
        private const val ROUTE_CONNECTION_WAIT_MS = 1000L
        private const val ROUTE_SETTLE_MS = 1000L
        private const val POLL_INTERVAL_MS = 50L
    }
}
