package app.cogwheel.conduit

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.os.RemoteException
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * The speech recognizer Conduit's assistant names as its own. Android checks
 * at boot that the assistant's recognizer exists, and drops an assistant that
 * names a missing one (#824). Some phones also make it the system recognizer
 * once Conduit is the assistant. Conduit has no recognizer of its own, so this
 * forwards every request to another installed one.
 */
class ConduitRecognitionService : RecognitionService() {
    private var delegate: SpeechRecognizer? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        releaseDelegate()
        val target = recognitionDelegate(installedRecognizers(this), packageName)
        if (target == null) {
            reportError(listener, SpeechRecognizer.ERROR_CLIENT)
            return
        }
        try {
            delegate = SpeechRecognizer.createSpeechRecognizer(this, target).also {
                it.setRecognitionListener(ForwardingListener(listener))
                it.startListening(recognizerIntent)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "Forwarding to $target failed", e)
            releaseDelegate()
            reportError(listener, SpeechRecognizer.ERROR_CLIENT)
        }
    }

    override fun onStopListening(listener: Callback) {
        delegate?.stopListening()
    }

    override fun onCancel(listener: Callback) {
        releaseDelegate()
    }

    override fun onDestroy() {
        releaseDelegate()
        super.onDestroy()
    }

    private fun releaseDelegate() {
        delegate?.destroy()
        delegate = null
    }

    private class ForwardingListener(
        private val listener: RecognitionService.Callback
    ) : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            forward { listener.readyForSpeech(params ?: Bundle()) }
        }

        override fun onBeginningOfSpeech() {
            forward { listener.beginningOfSpeech() }
        }

        override fun onRmsChanged(rmsdB: Float) {
            forward { listener.rmsChanged(rmsdB) }
        }

        override fun onBufferReceived(buffer: ByteArray?) {
            if (buffer != null) forward { listener.bufferReceived(buffer) }
        }

        override fun onEndOfSpeech() {
            forward { listener.endOfSpeech() }
        }

        override fun onError(error: Int) {
            forward { listener.error(error) }
        }

        override fun onResults(results: Bundle?) {
            forward { listener.results(results ?: Bundle()) }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            forward { listener.partialResults(partialResults ?: Bundle()) }
        }

        @RequiresApi(Build.VERSION_CODES.TIRAMISU)
        override fun onSegmentResults(segmentResults: Bundle) {
            forward { listener.segmentResults(segmentResults) }
        }

        @RequiresApi(Build.VERSION_CODES.TIRAMISU)
        override fun onEndOfSegmentedSession() {
            forward { listener.endOfSegmentedSession() }
        }

        @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        override fun onLanguageDetection(results: Bundle) {
            forward { listener.languageDetection(results) }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private companion object {
        const val TAG = "ConduitRecognition"

        fun reportError(listener: RecognitionService.Callback, error: Int) {
            forward { listener.error(error) }
        }

        inline fun forward(call: () -> Unit) {
            try {
                call()
            } catch (e: RemoteException) {
                Log.w(TAG, "The recognition client is gone", e)
            }
        }
    }
}

/** An installed speech recognizer Conduit could forward to. */
internal data class RecognizerCandidate(
    val component: ComponentName,
    val isSystem: Boolean
)

/**
 * The recognizer to forward to: never Conduit's own, and one that came with
 * the phone, normally its default, before any other.
 */
internal fun recognitionDelegate(
    candidates: List<RecognizerCandidate>,
    ownPackage: String
): ComponentName? {
    val others = candidates.filter { it.component.packageName != ownPackage }
    return (others.firstOrNull { it.isSystem } ?: others.firstOrNull())?.component
}

/**
 * Whether a recognizer other than Conduit's forwarding one is installed. The
 * platform's own check counts Conduit's, which hears nothing by itself.
 */
internal fun otherRecognizerInstalled(context: Context): Boolean =
    installedRecognizers(context).any {
        it.component.packageName != context.packageName
    }

private fun installedRecognizers(context: Context): List<RecognizerCandidate> =
    context.packageManager
        .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
        .map { it.serviceInfo }
        .map {
            RecognizerCandidate(
                component = ComponentName(it.packageName, it.name),
                isSystem = ((it.applicationInfo?.flags ?: 0) and
                    ApplicationInfo.FLAG_SYSTEM) != 0
            )
        }
