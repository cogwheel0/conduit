package app.cogwheel.conduit

import java.util.Locale

/**
 * The foss build ships no ML Kit, so there is no on-device speech model;
 * [NativeSttBridge] uses the platform recognizer instead. Same API as the
 * play build's version.
 */
internal object OnDeviceSpeechEngine {
    val isIncluded: Boolean = false

    @Suppress("UNUSED_PARAMETER")
    fun create(locale: Locale, mode: OnDeviceMode): OnDeviceRecognizer =
        throw UnsupportedOperationException("On-device speech recognition is not in this build")
}
