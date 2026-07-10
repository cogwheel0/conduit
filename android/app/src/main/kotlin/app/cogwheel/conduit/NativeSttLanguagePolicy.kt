package app.cogwheel.conduit

internal object NativeSttLanguagePolicy {
    private const val LANGUAGE_SWITCH_MIN_SDK = 34

    fun usesPlatformLanguageSwitch(localeId: String?, sdkInt: Int): Boolean {
        return localeId.isNullOrBlank() && sdkInt >= LANGUAGE_SWITCH_MIN_SDK
    }
}
