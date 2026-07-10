package app.cogwheel.conduit

internal object NativeSttLanguagePolicy {
    private const val LANGUAGE_SWITCH_MIN_SDK = 34

    fun usesPlatformLanguageSwitch(localeId: String?, sdkInt: Int): Boolean {
        return localeId.isNullOrBlank() && sdkInt >= LANGUAGE_SWITCH_MIN_SDK
    }

    fun hasMultipleLanguages(localeIds: List<String>): Boolean {
        return localeIds
            .mapNotNull(::primaryLanguage)
            .distinct()
            .size >= 2
    }

    fun preferredBaseLocale(requestedLocaleId: String, localeIds: List<String>): String {
        if (localeIds.isEmpty()) {
            return requestedLocaleId
        }
        val exact = localeIds.firstOrNull {
            it.equals(requestedLocaleId, ignoreCase = true)
        }
        if (exact != null) {
            return exact
        }
        val requestedLanguage = primaryLanguage(requestedLocaleId)
        return localeIds.firstOrNull { primaryLanguage(it) == requestedLanguage }
            ?: localeIds.first()
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
