package app.cogwheel.conduit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSttLanguagePolicyTest {
    @Test
    fun offlineModePrefersSystemOnDeviceRecognizer() {
        assertTrue(
            NativeSttLanguagePolicy.usesSystemOnDeviceRecognizer(
                allowOnlineFallback = false,
                sdkInt = 31,
                onDeviceRecognitionAvailable = true
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.usesSystemOnDeviceRecognizer(
                allowOnlineFallback = true,
                sdkInt = 31,
                onDeviceRecognitionAvailable = true
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.usesSystemOnDeviceRecognizer(
                allowOnlineFallback = false,
                sdkInt = 30,
                onDeviceRecognitionAvailable = true
            )
        )
    }

    @Test
    fun offlineModeFallsBackToAnyInstalledRecognizer() {
        // GrapheneOS: no Android System Intelligence, third-party service installed.
        assertTrue(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 31,
                recognitionAvailable = true,
                onDeviceRecognitionAvailable = false
            )
        )
        assertTrue(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 31,
                recognitionAvailable = false,
                onDeviceRecognitionAvailable = true
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 31,
                recognitionAvailable = false,
                onDeviceRecognitionAvailable = false
            )
        )
        assertFalse(
            NativeSttLanguagePolicy.platformRecognizerAvailable(
                allowOnlineFallback = false,
                sdkInt = 30,
                recognitionAvailable = false,
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

    @Test
    fun regionalRecoveryUsesOnlySupportedVariantsOfTheRequestedLanguage() {
        assertEquals(
            listOf("en-IN", "en-GB", "en-US"),
            NativeSttLanguagePolicy.fallbackLocaleIds(
                "en_IN", "pl-PL", listOf("pl-PL", "en-US", "en-IN", "en-GB")
            )
        )
        assertEquals(
            emptyList<String>(),
            NativeSttLanguagePolicy.fallbackLocaleIds("pl-PL", "en-US", listOf("en-US"))
        )
    }

    @Test
    fun explicitScriptIsPreservedDuringLanguageRecovery() {
        assertEquals(
            listOf("zh-Hant-TW"),
            NativeSttLanguagePolicy.fallbackLocaleIds(
                "zh-Hant-HK", "en-US", listOf("zh-Hans-CN", "zh-Hant-TW")
            )
        )
        assertEquals(
            listOf("zh-Hant"),
            NativeSttLanguagePolicy.fallbackLocaleIds("zh-Hant-HK", "en-US", null)
        )
    }

    @Test
    fun automaticRecoveryCanUseTheEngineDefaultAndSystemLanguageVariants() {
        assertEquals(
            listOf(null, "en-US"),
            NativeSttLanguagePolicy.fallbackLocaleIds(null, "en-IN", listOf("en-US", "pl-PL"))
        )
        assertEquals(
            listOf(null, "en"),
            NativeSttLanguagePolicy.fallbackLocaleIds(null, "en-IN", null)
        )
    }
}
