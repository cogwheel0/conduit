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
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * The speech recognizer Conduit's assistant names as its own. Android checks
 * at boot that the assistant's recognizer exists, and drops an assistant that
 * names a missing one (#824). Some phones also make it the system recognizer
 * once Conduit is the assistant. Conduit has no recognizer of its own, so this
 * forwards every request to the one that came with the phone.
 */
class ConduitRecognitionService : RecognitionService() {
    private var delegate: SpeechRecognizer? = null
    private var delegateTarget: ComponentName? = null

    override fun onStartListening(recognizerIntent: Intent, listener: Callback) {
        try {
            val recognizer = delegate()
            if (recognizer == null) {
                reportError(listener, SpeechRecognizer.ERROR_CLIENT)
                return
            }
            recognizer.setRecognitionListener(ForwardingListener(listener))
            recognizer.startListening(recognizerIntent)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Forwarding to $delegateTarget failed", e)
            releaseDelegate()
            reportError(listener, SpeechRecognizer.ERROR_CLIENT)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override fun onCheckRecognitionSupport(
        recognizerIntent: Intent,
        supportCallback: SupportCallback
    ) {
        val recognizer = delegate()
        if (recognizer == null) {
            supportCallback.onError(SpeechRecognizer.ERROR_CANNOT_CHECK_SUPPORT)
            return
        }
        recognizer.checkRecognitionSupport(
            recognizerIntent,
            mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(recognitionSupport: RecognitionSupport) {
                    supportCallback.onSupportResult(recognitionSupport)
                }

                override fun onError(error: Int) {
                    supportCallback.onError(error)
                }
            }
        )
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    override fun onTriggerModelDownload(recognizerIntent: Intent) {
        delegate()?.triggerModelDownload(recognizerIntent)
    }

    override fun onStopListening(listener: Callback) {
        delegate?.stopListening()
    }

    override fun onCancel(listener: Callback) {
        delegate?.cancel()
    }

    override fun onDestroy() {
        releaseDelegate()
        super.onDestroy()
    }

    /**
     * The phone's recognizer, kept for the whole session: rebinding it between
     * utterances can drop its connection (ERROR_SERVER_DISCONNECTED).
     */
    private fun delegate(): SpeechRecognizer? {
        val target = recognitionDelegate(installedRecognizers(this), packageName)
        if (target == null) {
            releaseDelegate()
            return null
        }
        if (delegate == null || delegateTarget != target) {
            releaseDelegate()
            delegate = SpeechRecognizer.createSpeechRecognizer(this, target)
            delegateTarget = target
        }
        return delegate
    }

    private fun releaseDelegate() {
        delegate?.destroy()
        delegate = null
        delegateTarget = null
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
 * The recognizer to forward to: one that came with the phone, normally its
 * default. Speech never goes to an installed app nobody chose for it, so with
 * no preinstalled recognizer there is none.
 */
internal fun recognitionDelegate(
    candidates: List<RecognizerCandidate>,
    ownPackage: String
): ComponentName? = candidates.firstOrNull {
    it.isSystem && it.component.packageName != ownPackage
}?.component

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
