package app.cogwheel.conduit

import kotlinx.coroutines.flow.Flow

/**
 * An on-device speech model, as [NativeSttBridge] uses it. The play build
 * backs it with ML Kit GenAI speech recognition; the foss build has no
 * on-device engine (`OnDeviceSpeechEngine.isIncluded` is false), so the
 * bridge falls back to the platform recognizer.
 */
internal interface OnDeviceRecognizer : AutoCloseable {
    suspend fun checkStatus(): OnDeviceStatus

    fun download(): Flow<OnDeviceDownload>

    /** Listens to the microphone until [stopRecognition] or completion. */
    fun startRecognition(): Flow<OnDeviceSpeechEvent>

    suspend fun stopRecognition()

    override fun close()
}

internal enum class OnDeviceMode { ADVANCED, BASIC }

internal enum class OnDeviceStatus { AVAILABLE, DOWNLOADABLE, DOWNLOADING, UNAVAILABLE }

internal sealed interface OnDeviceDownload {
    data object Started : OnDeviceDownload
    data object Completed : OnDeviceDownload
    data class Progress(val bytesDownloaded: Long) : OnDeviceDownload
    data class Failed(val code: Int, val message: String?) : OnDeviceDownload
}

internal sealed interface OnDeviceSpeechEvent {
    data class Partial(val text: String) : OnDeviceSpeechEvent
    data class Final(val text: String) : OnDeviceSpeechEvent
    data class Error(val code: Int, val message: String?) : OnDeviceSpeechEvent
    data object Completed : OnDeviceSpeechEvent
}
