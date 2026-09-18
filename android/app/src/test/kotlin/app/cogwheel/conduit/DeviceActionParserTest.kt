package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DeviceActionParserTest {
    @Test
    fun parsesAPlainToolCall() {
        val call = DeviceActionParser.parse(
            """{"tool":"set_alarm","args":{"hour":7,"minute":30,"label":"Wake up"}}""",
        )
        assertEquals(DeviceActions.SET_ALARM, call?.name)
        assertEquals(7, call?.args?.getInt("hour"))
        assertEquals(30, call?.args?.getInt("minute"))
        assertEquals("Wake up", call?.args?.getString("label"))
    }

    @Test
    fun parsesFencedToolCall() {
        val call = DeviceActionParser.parse(
            "```json\n{\"tool\":\"flashlight\",\"args\":{\"on\":true}}\n```",
        )
        assertEquals(DeviceActions.FLASHLIGHT, call?.name)
        assertEquals(true, call?.args?.getBoolean("on"))
    }

    @Test
    fun toleratesSurroundingWhitespace() {
        val call = DeviceActionParser.parse(
            "   \n {\"tool\":\"web_search\",\"args\":{\"query\":\"weather\"}}  \n",
        )
        assertEquals(DeviceActions.WEB_SEARCH, call?.name)
        assertEquals("weather", call?.args?.getString("query"))
    }

    @Test
    fun rejectsProse() {
        assertNull(
            DeviceActionParser.parse(
                "Sure! {\"tool\":\"flashlight\",\"args\":{\"on\":true}} hope that helps!",
            ),
        )
    }

    @Test
    fun rejectsUnknownToolNames() {
        assertNull(
            DeviceActionParser.parse("""{"tool":"factory_reset","args":{}}"""),
        )
    }

    @Test
    fun rejectsNonObjectsAndGarbage() {
        assertNull(DeviceActionParser.parse("[1,2,3]"))
        assertNull(DeviceActionParser.parse("Hello there!"))
        assertNull(DeviceActionParser.parse("{ not json"))
        assertNull(DeviceActionParser.parse(""))
        assertNull(DeviceActionParser.parse(null))
    }

    @Test
    fun missingArgsBecomesEmptyObject() {
        val call = DeviceActionParser.parse("""{"tool":"dial"}""")
        assertEquals(DeviceActions.DIAL, call?.name)
        assertEquals(0, call?.args?.length())
    }
}