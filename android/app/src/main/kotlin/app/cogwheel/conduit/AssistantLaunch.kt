package app.cogwheel.conduit

import android.content.Intent
import android.util.Log
import java.io.File
import java.io.IOException

/**
 * What the assistant asked Conduit to do when it opened the app, sent to Dart
 * on the assistant channel as [method] with [arguments].
 */
internal data class AssistantLaunchAction(
    val method: String,
    val arguments: Any?
) {
    fun toChannelValue(): Map<String, Any?> =
        mapOf("method" to method, "arguments" to arguments)

    companion object {
        const val EXTRA_START_VOICE_CALL = "start_voice_call"
        const val EXTRA_START_NEW_CHAT = "start_new_chat"
        const val EXTRA_FOCUS_COMPOSER = "focus_composer"
        const val EXTRA_SCREEN_CONTEXT = "screen_context"
        const val EXTRA_SCREENSHOT_PATH = "screenshot_path"

        /** Name prefix of the screenshots the assistant session caches. */
        const val SCREENSHOT_FILE_PREFIX = "assistant_screenshot_"

        private val extras = listOf(
            EXTRA_START_VOICE_CALL,
            EXTRA_START_NEW_CHAT,
            EXTRA_FOCUS_COMPOSER,
            EXTRA_SCREEN_CONTEXT,
            EXTRA_SCREENSHOT_PATH
        )

        /**
         * Reads the assistant's request from [intent] and removes it, so a
         * recreated activity does not repeat it. Reopening the app from
         * Recents replays the original launch intent, which asks for nothing.
         * A screenshot is accepted only from the app's [cacheDir].
         */
        fun take(intent: Intent, cacheDir: File): AssistantLaunchAction? {
            val fromHistory =
                (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
            val action = if (fromHistory) null else read(intent, cacheDir)
            extras.forEach(intent::removeExtra)
            return action
        }

        private fun read(intent: Intent, cacheDir: File): AssistantLaunchAction? {
            val screenContext = intent.getStringExtra(EXTRA_SCREEN_CONTEXT)
            val screenshotPath = intent.getStringExtra(EXTRA_SCREENSHOT_PATH)
            return when {
                intent.getBooleanExtra(EXTRA_START_VOICE_CALL, false) ->
                    AssistantLaunchAction("startVoiceCall", null)
                intent.getBooleanExtra(EXTRA_START_NEW_CHAT, false) ->
                    AssistantLaunchAction(
                        "startNewChat",
                        mapOf(
                            "focusComposer" to
                                intent.getBooleanExtra(EXTRA_FOCUS_COMPOSER, false)
                        )
                    )
                screenContext != null ->
                    AssistantLaunchAction("analyzeScreen", screenContext)
                screenshotPath != null ->
                    screenshotInCache(screenshotPath, cacheDir)?.let {
                        AssistantLaunchAction("analyzeScreenshot", it)
                    }
                else -> null
            }
        }

        /**
         * The canonical path of [path] when it is a screenshot the assistant
         * session wrote: a file directly inside [cacheDir] whose name starts
         * with [SCREENSHOT_FILE_PREFIX]. Any other path gives null.
         */
        private fun screenshotInCache(path: String, cacheDir: File): String? {
            val file = try {
                File(path).canonicalFile.takeIf {
                    it.parentFile == cacheDir.canonicalFile &&
                        it.name.startsWith(SCREENSHOT_FILE_PREFIX) &&
                        it.isFile
                }
            } catch (e: IOException) {
                null
            } catch (e: SecurityException) {
                null
            }
            if (file == null) {
                Log.d("AssistantLaunch", "Dropped a screenshot that is not in the app cache")
            }
            return file?.path
        }
    }
}

/**
 * Holds the assistant's latest request until Dart's handler asks for it. A
 * cold start delivers the launch intent before Dart runs, and a method call
 * sent then is lost, so the app opened without starting the call (#514).
 */
internal class AssistantLaunchQueue {
    private var dartListening = false
    private var pending: AssistantLaunchAction? = null

    /** Returns [action] to send now, or null when it is held for Dart. */
    fun offer(action: AssistantLaunchAction): AssistantLaunchAction? {
        if (dartListening) return action
        pending = action
        return null
    }

    /** Dart's handler is listening; returns the request it missed, if any. */
    fun startListening(): AssistantLaunchAction? {
        dartListening = true
        return pending.also { pending = null }
    }

    /** A new Flutter engine has no Dart handler yet. */
    fun reset() {
        dartListening = false
        pending = null
    }
}
