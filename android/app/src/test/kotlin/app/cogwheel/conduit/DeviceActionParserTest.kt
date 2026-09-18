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
    fun proseWrappingJsonStillParsesTheCall() {
        val call = DeviceActionParser.parse(
            "Sure! {\"tool\":\"flashlight\",\"args\":{\"on\":true}} hope that helps!",
        )
        assertEquals(DeviceActions.FLASHLIGHT, call?.name)
        assertEquals(true, call?.args?.getBoolean("on"))
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

    @Test
    fun parsesWeatherCall() {
        val call = DeviceActionParser.parse(
            """{"tool":"get_weather","args":{"location":"Madrid","days":2}}""",
        )
        assertEquals(DeviceActions.GET_WEATHER, call?.name)
        assertEquals("Madrid", call?.args?.getString("location"))
        assertEquals(2, call?.args?.getInt("days"))
    }

    @Test
    fun weatherCodesMapToDescriptions() {
        assertEquals("clear sky", DeviceActionExecutor.weatherDescription(0))
        assertEquals("partly cloudy", DeviceActionExecutor.weatherDescription(2))
        assertEquals("fog", DeviceActionExecutor.weatherDescription(45))
        assertEquals("heavy rain", DeviceActionExecutor.weatherDescription(65))
        assertEquals("rain showers", DeviceActionExecutor.weatherDescription(82))
        assertEquals("thunderstorm with hail", DeviceActionExecutor.weatherDescription(99))
        assertEquals("unknown conditions", DeviceActionExecutor.weatherDescription(42))
    }

    @Test
    fun parsesWebLookupCall() {
        val call = DeviceActionParser.parse(
            """{"tool":"web_lookup","args":{"query":"gemini nano context","maxResults":3}}""",
        )
        assertEquals(DeviceActions.WEB_LOOKUP, call?.name)
        assertEquals("gemini nano context", call?.args?.getString("query"))
    }

    @Test
    fun parsesBingRssResults() {
        val xml = "<rss><channel>" +
            "<item><title>First &amp; one</title>" +
            "<link>https://example.com/a?x=1&amp;y=2</link>" +
            "<description>Snippet &lt;b&gt;one&lt;/b&gt; text</description></item>" +
            "<item><title>Second</title><link>https://example.com/b</link>" +
            "<description>Snippet two</description></item>" +
            "</channel></rss>"
        val results = DeviceActionExecutor.parseBingRss(xml)
        assertEquals(2, results.size)
        assertEquals("First & one", results[0].first)
        assertEquals("https://example.com/a?x=1&y=2", results[0].third)
        assertEquals("Snippet one text", results[0].second)
        assertEquals("Second", results[1].first)
    }

    @Test
    fun toleratesMalformedRss() {
        assertEquals(0, DeviceActionExecutor.parseBingRss("not xml at all").size)
        assertEquals(1, DeviceActionExecutor.parseBingRss("<item><title>Only</title></item>").size)
    }

    @Test
    fun parsesProseWrappedToolCall() {
        val call = DeviceActionParser.parse(
            """I'll search the web for that. {"tool":"web_lookup","args":{"query":"news"}}""",
        )
        assertEquals(DeviceActions.WEB_LOOKUP, call?.name)
        assertEquals("news", call?.args?.getString("query"))
    }

    @Test
    fun proseWithTrailingTextStillParses() {
        val call = DeviceActionParser.parse(
            """{"tool":"flashlight","args":{"on":false}} hope that helps!""",
        )
        assertEquals(DeviceActions.FLASHLIGHT, call?.name)
        assertEquals(false, call?.args?.getBoolean("on"))
    }

    @Test
    fun rejectsProseMentioningToolNamesWithoutJson() {
        assertNull(DeviceActionParser.parse("I can set an alarm for you if you'd like!"))
    }

    @Test
    fun parsesGemmaControlTokenCall() {
        val call = DeviceActionParser.parse(
            "<ctrl42>call:web_search{query:\"next NBA game schedule\"}<ctrl43><ctrl44>",
        )
        assertEquals(DeviceActions.WEB_SEARCH, call?.name)
        assertEquals("next NBA game schedule", call?.args?.getString("query"))
    }

    @Test
    fun resolvesSchemaParrotingDecoratedNames() {
        val call = DeviceActionParser.parse(
            "<ctrl42>call:web_search or web_lookup {\"query\":\"next NBA game\"}<ctrl43><ctrl44>",
        )
        assertEquals(DeviceActions.WEB_SEARCH, call?.name)
        assertEquals("next NBA game", call?.args?.getString("query"))
    }

    @Test
    fun parsesGemmaCallWithLenientArgs() {
        val call = DeviceActionParser.parse(
            "call:set_alarm{hour:7, minute:30; label:\"Wake up\"}",
        )
        assertEquals(DeviceActions.SET_ALARM, call?.name)
        assertEquals(7, call?.args?.getInt("hour"))
        assertEquals(30, call?.args?.getInt("minute"))
        assertEquals("Wake up", call?.args?.getString("label"))
    }

    @Test
    fun parsesGemmaCallWrappedInProse() {
        val call = DeviceActionParser.parse(
            "Sure, one moment. call:flashlight{on:false}",
        )
        assertEquals(DeviceActions.FLASHLIGHT, call?.name)
        assertEquals(false, call?.args?.getBoolean("on"))
    }

    @Test
    fun singleQuotedValueWithCommaSurvivesArgSplitting() {
        val call = DeviceActionParser.parse(
            "call:compose_sms{body:'Hi, there'}",
        )
        assertEquals(DeviceActions.COMPOSE_SMS, call?.name)
        assertEquals("Hi, there", call?.args?.getString("body"))
    }

    @Test
    fun leavesShortSnippetsUntouched() {
        assertEquals("short", DeviceActionExecutor.truncateSnippet("short", 400))
    }

    @Test
    fun truncatesSnippetsAtWordBoundary() {
        val text = "a".repeat(200) + " end of sentence"
        val snippet = DeviceActionExecutor.truncateSnippet(text, 210)
        assertEquals("a".repeat(200) + " end of…", snippet)
    }

    @Test
    fun truncatesSnippetsAtHardLimitWithoutSpace() {
        val snippet = DeviceActionExecutor.truncateSnippet("b".repeat(500), 400)
        assertEquals(401, snippet.length) // 400 chars + ellipsis
    }
}