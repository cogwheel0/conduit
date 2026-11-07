package app.cogwheel.conduit

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Opens Conduit from a Quick Settings tile, deferring to the unlock prompt when
 * the phone is locked.
 *
 * The tiles are ways in, not a second implementation of anything: they hand
 * MainActivity the same [AssistantLaunchAction] extras the assistant launch
 * uses, so what "start a new chat" or "start a voice call" means stays in one
 * place, on the Dart side.
 */
@RequiresApi(Build.VERSION_CODES.N)
internal fun TileService.openConduit(requestCode: Int, launch: Intent) {
    val open = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // The Intent overload is deprecated from 34 in favour of a
            // PendingIntent, which is how the system launches it for us. The
            // request code keeps one tile's PendingIntent from being reused for
            // the other's launch: filterEquals ignores the extras.
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    requestCode,
                    launch,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launch)
        }
    }
    if (isLocked) {
        // The app cannot come up over the keyguard, so wait for the unlock the
        // user is about to do anyway rather than collapsing onto nothing.
        unlockAndRun(open)
    } else {
        open()
    }
}

/**
 * The launch intent for a tile: the app itself, brought forward rather than
 * stacked again, as the assistant's own launches do.
 */
@RequiresApi(Build.VERSION_CODES.N)
internal fun TileService.conduitLaunchIntent(): Intent =
    Intent(this, MainActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
    }

/** What the Ask tile opens: a new chat, with the composer ready to type in. */
@RequiresApi(Build.VERSION_CODES.N)
internal fun TileService.askLaunchIntent(): Intent = conduitLaunchIntent().apply {
    putExtra(AssistantLaunchAction.EXTRA_START_NEW_CHAT, true)
    putExtra(AssistantLaunchAction.EXTRA_FOCUS_COMPOSER, true)
}

/** Quick Settings tile: a new chat. */
@RequiresApi(Build.VERSION_CODES.N)
class AskTileService : TileService() {
    override fun onClick() {
        super.onClick()
        openConduit(ASK_REQUEST_CODE, askLaunchIntent())
    }

    private companion object {
        // Distinct per tile: two PendingIntents that differ only in extras
        // compare equal, so one would overwrite the other.
        const val ASK_REQUEST_CODE = 1
    }
}

/** What the Voice tile opens: a voice conversation, and nothing else. */
@RequiresApi(Build.VERSION_CODES.N)
internal fun TileService.voiceLaunchIntent(): Intent = conduitLaunchIntent().apply {
    putExtra(AssistantLaunchAction.EXTRA_START_VOICE_CALL, true)
}

/** Quick Settings tile: a voice conversation. */
@RequiresApi(Build.VERSION_CODES.N)
class VoiceTileService : TileService() {
    override fun onClick() {
        super.onClick()
        openConduit(VOICE_REQUEST_CODE, voiceLaunchIntent())
    }

    private companion object {
        const val VOICE_REQUEST_CODE = 2
    }
}
