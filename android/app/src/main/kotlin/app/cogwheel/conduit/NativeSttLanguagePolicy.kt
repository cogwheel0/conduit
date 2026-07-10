package app.cogwheel.conduit

internal object NativeSttLanguagePolicy {
    private const val ON_DEVICE_RECOGNIZER_MIN_SDK = 31
    private const val LANGUAGE_SWITCH_MIN_SDK = 34

    fun platformRecognizerAvailable(
        allowOnlineFallback: Boolean,
        sdkInt: Int,
        recognitionAvailable: Boolean,
        onDeviceRecognitionAvailable: Boolean
    ): Boolean {
        return if (allowOnlineFallback) {
            recognitionAvailable
        } else {
            sdkInt >= ON_DEVICE_RECOGNIZER_MIN_SDK && onDeviceRecognitionAvailable
        }
    }

    fun usesPlatformLanguageSwitch(localeId: String?, sdkInt: Int): Boolean {
        return localeId.isNullOrBlank() && sdkInt >= LANGUAGE_SWITCH_MIN_SDK
    }

    fun hasMultipleLanguages(localeIds: List<String>): Boolean {
        return localeIds
            .mapNotNull(::primaryLanguage)
            .distinct()
            .size >= 2
    }

    private fun primaryLanguage(localeId: String): String? {
        return localeId
            .trim()
            .replace('_', '-')
            .substringBefore('-')
            .lowercase()
            .takeIf { it.isNotBlank() }
    }
}
