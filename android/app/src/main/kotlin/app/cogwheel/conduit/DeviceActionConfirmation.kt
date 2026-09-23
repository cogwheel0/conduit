package app.cogwheel.conduit

import android.app.Activity
import android.app.AlertDialog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.Locale

/** A pending device action rendered for the user-approval dialog. */
data class DeviceActionConfirmation(
    val title: String,
    val message: String,
)

/**
 * Human-readable summaries of state-changing device actions, shown in the
 * confirmation dialog so the user can judge what the assistant is about to
 * do. Lenient with missing or malformed arguments: a summary is always
 * produced, never a crash.
 */
object DeviceActionPrompts {
    /** One-line summary of the pending action for the approval dialog. */
    fun describe(name: String, args: JSONObject): String = when (name) {
        DeviceActions.SET_ALARM -> describeAlarm(args)
        DeviceActions.SET_TIMER -> describeTimer(args)
        DeviceActions.FLASHLIGHT -> describeFlashlight(args)
        DeviceActions.SET_VOLUME -> describeVolume(args)
        else -> "Perform the '$name' action"
    }

    private fun describeAlarm(args: JSONObject): String {
        val hour = args.optInt("hour", -1)
        val minute = args.optInt("minute", -1)
        if (hour !in 0..23 || minute !in 0..59) return "Set an alarm"
        val time = String.format(Locale.US, "%02d:%02d", hour, minute)
        return "Set an alarm for $time"
    }

    private fun describeTimer(args: JSONObject): String {
        val seconds = args.optInt("seconds", -1)
        if (seconds <= 0 || seconds > 86_400) return "Start a timer"
        return when {
            seconds % 3_600 == 0 -> "Start a ${seconds / 3_600} hour timer"
            seconds % 60 == 0 -> "Start a ${seconds / 60} minute timer"
            else -> "Start a timer for ${seconds / 60} min ${seconds % 60} s"
        }
    }

    private fun describeFlashlight(args: JSONObject): String = when {
        args.has("on") && args.optBoolean("on") -> "Turn the flashlight on"
        args.has("on") -> "Turn the flashlight off"
        else -> "Toggle the flashlight"
    }

    private fun describeVolume(args: JSONObject): String {
        val percent = args.optInt("volumePercent", -1)
        if (percent !in 0..100) return "Set the device volume"
        val stream = when (args.optString("stream", "media")) {
            "ring" -> "ringer"
            "alarm" -> "alarm"
            "notification" -> "notification"
            else -> "media"
        }
        return "Set $stream volume to $percent percent"
    }

    /** Explanation shown under the action summary in the approval dialog. */
    const val CONFIRMATION_MESSAGE: String =
        "Conduit is about to change something on this device. " +
            "Allow it only if you asked for this."
}

/**
 * The approval gate the bridge consults before executing a state-changing
 * action. Model output — however it was prompted, including untrusted web
 * content replayed in chat history — can never silently mutate device state:
 * a human approves (or declines) every such action.
 */
fun interface DeviceActionApproval {
    /** Returns true only when the user explicitly approved the action. */
    suspend fun awaitApproval(confirmation: DeviceActionConfirmation): Boolean
}

/**
 * Production [DeviceActionApproval]: shows the confirmation over the
 * foreground activity. Fails closed — without an activity to host the dialog
 * or when the user does not answer in time, the action is treated as denied.
 */
class ActivityActionApproval(
    private val activityProvider: () -> Activity?,
) : DeviceActionApproval {
    override suspend fun awaitApproval(confirmation: DeviceActionConfirmation): Boolean {
        val activity = activityProvider() ?: return false
        return withContext(Dispatchers.Main.immediate) {
            val decision = CompletableDeferred<Boolean>()
            var dialog: AlertDialog? = null
            try {
                dialog = AlertDialog.Builder(activity)
                    .setTitle(confirmation.title)
                    .setMessage(confirmation.message)
                    .setPositiveButton(APPROVE_LABEL) { _, _ -> decision.complete(true) }
                    .setNegativeButton(DENY_LABEL) { _, _ -> decision.complete(false) }
                    .setOnCancelListener { decision.complete(false) }
                    .show()
            } catch (_: Exception) {
                decision.complete(false)
            }
            try {
                withTimeoutOrNull(CONFIRMATION_TIMEOUT_MILLIS) { decision.await() }
                    ?: false
            } finally {
                // A timeout or cancelled wait leaves the dialog on screen;
                // dismiss it so the boundary cannot linger over the app.
                decision.complete(false)
                runCatching { dialog?.dismiss() }
            }
        }
    }

    companion object {
        /** Bounded wait so an unattended dialog cannot hold the turn open. */
        const val CONFIRMATION_TIMEOUT_MILLIS = 60_000L

        const val APPROVE_LABEL = "Allow"
        const val DENY_LABEL = "Don't allow"
    }
}