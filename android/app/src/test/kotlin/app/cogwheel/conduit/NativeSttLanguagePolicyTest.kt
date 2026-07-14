package app.cogwheel.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSttLanguagePolicyTest {
    @Test
    fun offlinePlatformFallbackRequiresVerifiedOnDeviceRecognizer() {
        assertTrue(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 31,
                recognitionAvailable = true,
                onDeviceRecognitionAvailable = true
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 31,
                recognitionAvailable = true,
                onDeviceRecognitionAvailable = false
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 30,
                recognitionAvailable = true,
                onDeviceRecognitionAvailable = true
            )
        )
    }

    @Test
    fun onlinePlatformFallbackUsesGeneralRecognizerAvailability() {
        assertTrue(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = true,
                sdkInt = 31,
                recognitionAvailable = true,
                onDeviceRecognitionAvailable = false
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = true,
                sdkInt = 31,
                recognitionAvailable = false,
                onDeviceRecognitionAvailable = true
            )
        )
    }

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
    fun installedLocaleIdsAreNormalizedDeduplicatedAndSorted() {
        assertEquals(
            listOf("en-US", "pl-PL"),
            NativeSttLanguagePolicy.normalizeLocaleIds(
                listOf("pl_PL", " en-US ", "EN-us", "")
            )
        )
    }
}
