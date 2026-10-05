package app.cogwheel.conduit

import java.util.Locale

internal object NativeSttLanguagePolicy {
    private const val ON_DEVICE_RECOGNIZER_MIN_SDK = 31
    private const val LANGUAGE_SWITCH_MIN_SDK = 34

    /**
     * Whether the strict system on-device recognizer must be used. When it is
     * absent (e.g. GrapheneOS without Android System Intelligence, issue #721)
     * the general recognizer is used with EXTRA_PREFER_OFFLINE so an installed
     * third-party RecognitionService can serve device mode.
     */
    fun usesSystemOnDeviceRecognizer(
        allowOnlineFallback: Boolean,
        sdkInt: Int,
        onDeviceRecognitionAvailable: Boolean
    ): Boolean {
        return !allowOnlineFallback &&
            sdkInt >= ON_DEVICE_RECOGNIZER_MIN_SDK &&
            onDeviceRecognitionAvailable
    }

    fun platformRecognizerAvailable(
        allowOnlineFallback: Boolean,
        sdkInt: Int,
        recognitionAvailable: Boolean,
        onDeviceRecognitionAvailable: Boolean
    ): Boolean {
        return recognitionAvailable ||
            usesSystemOnDeviceRecognizer(
                allowOnlineFallback,
                sdkInt,
                onDeviceRecognitionAvailable
            )
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

    fun normalizeLocaleIds(localeIds: List<String>): List<String> {
        return localeIds
            .map { it.trim().replace('_', '-') }
            .filter { it.isNotBlank() }
            .distinctBy { it.lowercase(Locale.ROOT) }
            .sortedBy { it.lowercase(Locale.ROOT) }
    }

    /**
     * Recovery stays within the requested language and script. Older engines
     * that cannot list languages get a language-only retry instead of another
     * guessed region. Automatic recognition may also use the engine default.
     * The caller removes failed requests and limits the number of attempts.
     */
    fun fallbackLocaleIds(
        localeId: String?,
        systemLocaleId: String,
        supportedLocaleIds: List<String>?
    ): List<String?> {
        val requested = Locale.forLanguageTag(
            (localeId?.takeIf { it.isNotBlank() } ?: systemLocaleId)
                .trim().replace('_', '-')
        )
        val candidates = if (supportedLocaleIds != null) {
            normalizeLocaleIds(supportedLocaleIds)
                .map(Locale::forLanguageTag)
                .filter {
                    it.language == requested.language &&
                        (requested.script.isBlank() || it.script == requested.script)
                }
                .sortedBy { if (it == requested) 0 else 1 }
                .map(Locale::toLanguageTag)
        } else if (requested.language.isNotBlank()) {
            listOf(Locale.Builder().setLanguage(requested.language)
                .setScript(requested.script).build().toLanguageTag())
        } else {
            emptyList()
        }
        return buildList {
            if (localeId.isNullOrBlank()) add(null)
            addAll(candidates)
        }.distinct()
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
