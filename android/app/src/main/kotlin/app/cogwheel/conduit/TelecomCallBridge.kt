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
 * The route to hold the call on, which is what the caller asked for rather
 * than what Telecom says the call is already doing.
 *
 * Telecom keeps reporting the route it accepted even after it threw the
 * request away (see [TelecomCallBridge]), so the bridge cannot decide a
 * re-request is unnecessary from Telecom's own answer: only the phone's
 * read-back knows whether the call went where it was asked to.
 */
internal fun telecomAudioRouteToHold(speaker: Boolean, route: Int?, supportedRoutes: Int): Int =
    when {
        speaker -> CallAudioState.ROUTE_SPEAKER
        route != null && route != CallAudioState.ROUTE_SPEAKER -> route
        (supportedRoutes and CallAudioState.ROUTE_BLUETOOTH) != 0 -> CallAudioState.ROUTE_BLUETOOTH
        else -> CallAudioState.ROUTE_WIRED_OR_EARPIECE
    }

/** The parts of the plugin's self-managed Telecom connection this bridge drives. */
internal interface TelecomCall {
    /** The route Telecom reports for the call, or null before it reports one. */
    val audioRoute: Int?

    /** The routes Telecom says the call can move to, as a [CallAudioState] mask. */
    val supportedRoutes: Int

    /** Asks Telecom to move the call to [route]. */
    fun setAudioRoute(route: Int)
}

/** The plugin's connection, which exists once Telecom has bound it. */
@RequiresApi(Build.VERSION_CODES.O)
private class PluginCall(private val connection: CallkitConnection) : TelecomCall {
    // Deprecated from Android 14 in favour of call endpoints, which this
    // plugin's connection does not track; Telecom still honours both.
    @Suppress("DEPRECATION")
    override val audioRoute: Int? get() = connection.callAudioState?.route

    @Suppress("DEPRECATION")
    override val supportedRoutes: Int
        get() = connection.callAudioState?.supportedRouteMask ?: 0

    override fun setAudioRoute(route: Int) = connection.setAudioRoute(route)
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
 *
 * A route request is not safe to make once, either. Telecom takes it lazily,
 * and a focus switch re-derives the call's base route as the audio mode
 * changes, throwing away a request it had not applied yet. The next read-back
 * then finds the call on the earpiece while the speaker button says otherwise.
 * So the bridge holds the request against the read-back for as long as its
 * wait lasts, re-asking while the phone disagrees (issue #716's own round).
 */
internal class TelecomCallBridge(
    context: Context,
    /** Whether the phone is playing the call through its own loudspeaker now. */
    private val loudspeaker: () -> Boolean = loudspeakerReadBack(context.applicationContext),
    /**
     * The call the bridge should drive, by call id, replacing the plugin's
     * connection registry. Tests use it to drive a call Telecom never created;
     * when it is set it is the only source, so answering null means the call is
     * not Telecom's to route.
     */
    private val callLookup: ((String) -> TelecomCall?)? = null,
) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())

    // The call the last lookup settled for, found or given up on. Only the
    // first lookups for a call wait for Telecom to create its connection.
    private var lookedUpCallId: String? = null

    // The route request that owns the call now. A press that follows another
    // one takes the route over, so the older wait stops re-asking for a route
    // nobody wants any more.
    private var routeGeneration = 0

    // A hold keeps posting after it has answered, so the answer slot does not
    // say whether it is still asking. A superseded hold leaves this set: the
    // press that replaced it has to know the previous one had not stopped.
    private var routeHoldRunning = false

    // Whether the engine is gone. A lookup still polling then has to answer
    // rather than leave its caller waiting on a channel that no longer exists:
    // the caller's route queue is serialized behind that answer.
    private var disposed = false

    // Callers waiting for Telecom to create their connection, with the answer
    // each gets if the engine goes away first.
    private val waitingForConnection = mutableMapOf<MethodChannel.Result, () -> Unit>()

    // One answer slot per route request still owed an answer, keyed by its
    // generation: a superseded hold answers its own caller and leaves the one
    // that replaced it alone.
    private val pendingAnswers = mutableMapOf<Int, MethodChannel.Result>()

    fun setup(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(this)
    }

    /** Stops a route request still being held, for when the engine goes away. */
    fun dispose() {
        disposed = true
        routeGeneration += 1
        routeHoldRunning = false
        main.removeCallbacksAndMessages(null)
        // Remove-callbacks also drops the lookups still polling, and their
        // callers would never hear back otherwise.
        val stranded = waitingForConnection.toMap()
        waitingForConnection.clear()
        stranded.values.forEach { it() }
        pendingAnswers.keys.toList().forEach { settle(it) }
    }

    /** Answers the request [generation] still owes, with where the phone is. */
    private fun settle(generation: Int) {
        val pending = pendingAnswers.remove(generation) ?: return
        pending.success(mapOf("loudspeaker" to loudspeaker()))
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
                findCall(
                    callId,
                    SystemClock.uptimeMillis() + CONNECTED_WAIT_MS,
                    result,
                    onMissing = { result.success(false) },
                ) {
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
        // A new press owns the route from here, even when it finds no call to
        // move: a hold left over from the press before it must let go.
        routeGeneration += 1
        val generation = routeGeneration
        val wait = if (lookedUpCallId == callId) 0L else ROUTE_CONNECTION_WAIT_MS
        findCall(
            callId,
            SystemClock.uptimeMillis() + wait,
            result,
            onMissing = { result.success(null) },
        ) { telecomCall ->
            if (telecomCall == null) {
                // Nothing to hold, and this press already took the route over.
                if (generation == routeGeneration) routeHoldRunning = false
                result.success(null)
            } else if (generation != routeGeneration) {
                // A newer press found the call while this lookup was still
                // polling, and owns the route now. Asking for this press's
                // route would undo that one, so this only answers, with where
                // the phone is, as a superseded hold does.
                result.success(mapOf("loudspeaker" to loudspeaker()))
            } else {
                routeAudio(telecomCall, speaker, generation, result)
            }
        }
    }

    /** Calls [found] with the call's connection once Telecom has created it. */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun findCall(
        callId: String,
        deadline: Long,
        result: MethodChannel.Result,
        onMissing: () -> Unit,
        found: (TelecomCall?) -> Unit,
    ) {
        if (disposed) {
            onMissing()
            return
        }
        val call = if (callLookup != null) {
            callLookup.invoke(callId)
        } else {
            CallkitConnection.find(callId)?.let(::PluginCall)
        }
        if (call != null || SystemClock.uptimeMillis() >= deadline) {
            lookedUpCallId = callId
            waitingForConnection.remove(result)
            found(call)
            return
        }
        waitingForConnection[result] = onMissing
        main.postDelayed(
            { findCall(callId, deadline, result, onMissing, found) },
            POLL_INTERVAL_MS,
        )
    }

    /**
     * Asks Telecom to play the call on the loudspeaker, or off it, and answers
     * once AudioManager shows the route or the wait runs out.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun routeAudio(
        call: TelecomCall,
        speaker: Boolean,
        generation: Int,
        result: MethodChannel.Result,
    ) {
        pendingAnswers[generation] = result
        val route = call.audioRoute
        val supportedRoutes = call.supportedRoutes
        // Telecom's report can already match this press, or still show the
        // route from before the hold. Neither means the phone is playing it
        // there, and the next re-ask is 400 ms away, past the 900 ms the
        // caller gives this press. So the press asks for the route it would
        // re-ask for, now, while a hold is running or while the phone's own
        // read-back disagrees with the press. Otherwise a route Telecom
        // already reports as correct stays put.
        val holdWasRunning = routeHoldRunning
        if (holdWasRunning || loudspeaker() != speaker) {
            call.setAudioRoute(telecomAudioRouteToHold(speaker, route, supportedRoutes))
        } else {
            telecomAudioRouteFor(speaker, route, supportedRoutes)?.let(call::setAudioRoute)
        }
        val now = SystemClock.uptimeMillis()
        holdRoute(
            call,
            speaker,
            telecomAudioRouteToHold(speaker, route, supportedRoutes),
            deadline = now + ROUTE_HOLD_MS,
            nextAskAt = now + REASSERT_INTERVAL_MS,
            confirmBy = now + ROUTE_CONFIRM_MS,
            generation = generation,
        )
    }

    /**
     * Keeps asking Telecom for the route the call was told to take while the
     * phone is not playing it there, and answers the caller once.
     *
     * Telecom applies a route change asynchronously, so the first request only
     * means it left. The call's own audio focus switch can follow and clear a
     * request that has not landed yet: asking again is what moves the call, and
     * not asking again is what left calls on the earpiece over a speaker button
     * that said otherwise.
     *
     * The answer waits for the route to show, but no longer than
     * [ROUTE_CONFIRM_MS]: the caller reads the route back itself straight after
     * this returns and reverts the speaker button if the two disagree, so
     * answering before Telecom had its chance would undo the press. Past that
     * window the hold keeps asking in the background, so the caller is not held
     * for the whole wait.
     */
    private fun holdRoute(
        call: TelecomCall,
        speaker: Boolean,
        route: Int,
        deadline: Long,
        nextAskAt: Long,
        confirmBy: Long,
        generation: Int,
    ) {
        val now = SystemClock.uptimeMillis()
        val loudspeaker = loudspeaker()
        if (generation != routeGeneration) {
            // A newer press owns the route now, and owns the running flag.
            settle(generation)
            return
        }
        if (loudspeaker == speaker || now >= deadline) {
            routeHoldRunning = false
            settle(generation)
            return
        }
        if (now >= confirmBy) settle(generation)
        val askAt = if (now >= nextAskAt) {
            call.setAudioRoute(route)
            now + REASSERT_INTERVAL_MS
        } else {
            nextAskAt
        }
        routeHoldRunning = true
        main.postDelayed({
            holdRoute(call, speaker, route, deadline, askAt, confirmBy, generation)
        }, POLL_INTERVAL_MS)
    }

    companion object {
        private const val METHOD_CHANNEL = "app.cogwheel.conduit/telecom_call"
        private const val CONNECTED_WAIT_MS = 5000L
        private const val ROUTE_CONNECTION_WAIT_MS = 1000L

        // Long enough to cover the audio focus switch a call goes through as
        // it becomes active, which is where a route request gets dropped.
        private const val ROUTE_HOLD_MS = 2500L

        // How long the answer waits for the route to show before it reports
        // where the phone is anyway. Measured on a phone: the route lands
        // 420-600 ms after the ask, on the re-ask that follows the switch.
        private const val ROUTE_CONFIRM_MS = 900L

        // A request still unanswered after this long was dropped on the way.
        private const val REASSERT_INTERVAL_MS = 400L
        private const val POLL_INTERVAL_MS = 50L
    }
}

/**
 * The same read-back the call coordinator makes through audio_session, with
 * its AudioManager resolved once: a held route reads it every 50 ms.
 */
private fun loudspeakerReadBack(context: Context): () -> Boolean {
    val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    return { isOnLoudspeaker(audioManager) }
}

private fun isOnLoudspeaker(audioManager: AudioManager): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val device = audioManager.communicationDevice
        if (device != null) {
            return device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        }
    }
    @Suppress("DEPRECATION")
    return audioManager.isSpeakerphoneOn
}
