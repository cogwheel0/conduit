package app.cogwheel.conduit

import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ResolveInfo
import android.content.pm.ServiceInfo
import android.speech.RecognitionService
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSessionService
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.w3c.dom.Element

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE)
class AssistantComponentsTest {
    private val androidNs = "http://schemas.android.com/apk/res/android"
    private val conduit = "app.cogwheel.conduit"

    @Test
    fun theAssistantKeepsTheClassNameAndroidRemembers() {
        val name = serviceWithAction(VoiceInteractionService.SERVICE_INTERFACE)

        // Renaming it would unset Conduit as the assistant on update.
        assertEquals("$conduit.ConduitVoiceInteractionSessionService", name)
        assertTrue(
            VoiceInteractionService::class.java
                .isAssignableFrom(Class.forName(name))
        )
    }

    @Test
    fun theAssistantNamesASessionServiceAndRecognizerConduitShips() {
        val info = parse(File("src/main/res/xml/voice_interaction_service.xml"))
            .documentElement
        val session = info.getAttributeNS(androidNs, "sessionService")
        val recognizer = info.getAttributeNS(androidNs, "recognitionService")

        assertTrue(
            VoiceInteractionSessionService::class.java
                .isAssignableFrom(Class.forName(session))
        )
        assertTrue(session in declaredServices())
        // Android drops an assistant whose recognizer it cannot find (#824).
        assertTrue(recognizer.startsWith("$conduit."))
        assertTrue(
            RecognitionService::class.java
                .isAssignableFrom(Class.forName(recognizer))
        )
        assertEquals(
            recognizer,
            serviceWithAction(RecognitionService.SERVICE_INTERFACE)
        )
    }

    @Test
    fun recognitionIsForwardedToTheRecognizerThatCameWithThePhone() {
        val own = candidate(conduit, isSystem = false)
        val store = candidate("store.speech", isSystem = false)
        val system = candidate("system.speech", isSystem = true)

        assertEquals(
            system.component,
            recognitionDelegate(listOf(own, store, system), conduit)
        )
        assertEquals(store.component, recognitionDelegate(listOf(own, store), conduit))
        assertNull(recognitionDelegate(listOf(own), conduit))
    }

    @Test
    fun conduitsOwnRecognizerDoesNotCountAsSpeechRecognition() {
        val context = RuntimeEnvironment.getApplication()
        val packageManager = shadowOf(context.packageManager)
        val intent = Intent(RecognitionService.SERVICE_INTERFACE)
        packageManager.addResolveInfoForIntent(
            intent,
            resolveInfo(context.packageName, "ConduitRecognitionService")
        )

        assertFalse(otherRecognizerInstalled(context))

        packageManager.addResolveInfoForIntent(
            intent,
            resolveInfo("test.speech", "RecognitionService")
        )
        assertTrue(otherRecognizerInstalled(context))
    }

    private fun candidate(packageName: String, isSystem: Boolean) =
        RecognizerCandidate(ComponentName(packageName, "Recognizer"), isSystem)

    private fun resolveInfo(packageName: String, name: String) =
        ResolveInfo().apply {
            serviceInfo = ServiceInfo().apply {
                this.packageName = packageName
                this.name = name
                applicationInfo = ApplicationInfo()
            }
        }

    private fun parse(file: File) = DocumentBuilderFactory.newInstance()
        .apply { isNamespaceAware = true }
        .newDocumentBuilder()
        .parse(file)

    private fun services(): List<Element> {
        val nodes = parse(File("src/main/AndroidManifest.xml"))
            .getElementsByTagName("service")
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    private fun Element.className(): String {
        val name = getAttributeNS(androidNs, "name")
        return if (name.startsWith(".")) "$conduit$name" else name
    }

    private fun declaredServices() = services().map { it.className() }

    private fun serviceWithAction(action: String): String {
        val matches = services().filter { service ->
            val actions = service.getElementsByTagName("action")
            (0 until actions.length).any {
                (actions.item(it) as Element)
                    .getAttributeNS(androidNs, "name") == action
            }
        }
        assertEquals(1, matches.size)
        return matches.single().className()
    }
}
