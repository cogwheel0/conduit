package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSttLanguagePolicyTest {
    @Test
    fun automaticSwitchRequiresAndroid14AndNoExplicitLocale() {
        assertTrue(NativeSttLanguagePolicy.usesPlatformLanguageSwitch(null, 34))
        assertFalse(NativeSttLanguagePolicy.usesPlatformLanguageSwitch("pl-PL", 34))
        assertFalse(NativeSttLanguagePolicy.usesPlatformLanguageSwitch(null, 33))
    }

    @Test
    fun automaticSwitchRequiresTwoDistinctLanguages() {
        assertTrue(NativeSttLanguagePolicy.hasMultipleLanguages(listOf("en-US", "pl-PL")))
        assertFalse(NativeSttLanguagePolicy.hasMultipleLanguages(listOf("en-US", "en-GB")))
    }

    @Test
    fun preferredBaseLocaleUsesClosestInstalledLanguage() {
        assertEquals(
            "en-US",
            NativeSttLanguagePolicy.preferredBaseLocale(
                "en-IN",
                listOf("pl-PL", "en-US")
            )
        )
        assertEquals(
            "pl-PL",
            NativeSttLanguagePolicy.preferredBaseLocale(
                "de-DE",
                listOf("pl-PL", "en-US")
            )
        )
    }
}
