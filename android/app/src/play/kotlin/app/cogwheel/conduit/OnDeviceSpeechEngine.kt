package app.cogwheel.conduit

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.audio.AudioSource
import com.google.mlkit.genai.speechrecognition.SpeechRecognition
import com.google.mlkit.genai.speechrecognition.SpeechRecognizer
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.SpeechRecognizerResponse
import com.google.mlkit.genai.speechrecognition.speechRecognizerOptions
import com.google.mlkit.genai.speechrecognition.speechRecognizerRequest
import java.util.Locale
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull

/** ML Kit GenAI speech recognition, in the play build only. */
internal object OnDeviceSpeechEngine {
    val isIncluded: Boolean = true

    fun create(locale: Locale, mode: OnDeviceMode): OnDeviceRecognizer {
        val options = speechRecognizerOptions {
            this.locale = locale
            preferredMode = when (mode) {
                OnDeviceMode.ADVANCED -> SpeechRecognizerOptions.Mode.MODE_ADVANCED
                OnDeviceMode.BASIC -> SpeechRecognizerOptions.Mode.MODE_BASIC
            }
        }
        return MlKitRecognizer(SpeechRecognition.getClient(options))
    }
}

private class MlKitRecognizer(private val recognizer: SpeechRecognizer) : OnDeviceRecognizer {
    override suspend fun checkStatus(): OnDeviceStatus = when (recognizer.checkStatus()) {
        FeatureStatus.AVAILABLE -> OnDeviceStatus.AVAILABLE
        FeatureStatus.DOWNLOADABLE -> OnDeviceStatus.DOWNLOADABLE
        FeatureStatus.DOWNLOADING -> OnDeviceStatus.DOWNLOADING
        else -> OnDeviceStatus.UNAVAILABLE
    }

    override fun download(): Flow<OnDeviceDownload> = recognizer.download().mapNotNull { status ->
        when (status) {
            is DownloadStatus.DownloadStarted -> OnDeviceDownload.Started
            is DownloadStatus.DownloadCompleted -> OnDeviceDownload.Completed
            is DownloadStatus.DownloadProgress -> OnDeviceDownload.Progress(status.totalBytesDownloaded)
            is DownloadStatus.DownloadFailed -> OnDeviceDownload.Failed(status.e.errorCode, status.e.message)
            else -> null
        }
    }

    override fun startRecognition(): Flow<OnDeviceSpeechEvent> {
        val request = speechRecognizerRequest {
            audioSource = AudioSource.fromMic()
        }
        return recognizer.startRecognition(request).mapNotNull { response ->
            when (response) {
                is SpeechRecognizerResponse.PartialTextResponse -> OnDeviceSpeechEvent.Partial(response.text)
                is SpeechRecognizerResponse.FinalTextResponse -> OnDeviceSpeechEvent.Final(response.text)
                is SpeechRecognizerResponse.ErrorResponse ->
                    OnDeviceSpeechEvent.Error(response.e.errorCode, response.e.message)
                is SpeechRecognizerResponse.CompletedResponse -> OnDeviceSpeechEvent.Completed
                else -> null
            }
        }
    }

    override suspend fun stopRecognition() {
        recognizer.stopRecognition()
    }

    override fun close() {
        recognizer.close()
    }
}
