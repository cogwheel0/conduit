package app.cogwheel.conduit.push

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PushPayloadTest {
    @Test
    fun parsesEveryVectorCase() {
        PushVectors.cases().forEach { case ->
            val name = case.getString("name")
            val expected = case.getJSONObject("payload")
            val payload = checkNotNull(PushPayload.parse(case.bytes("plaintext"))) { "$name did not parse" }

            assertEquals(name, expected.getString("k"), payload.kind)
            assertEquals(name, expected.getString("src"), payload.source)
            assertEquals(name, expected.getString("t"), payload.title)
            assertEquals(name, expected.getString("b"), payload.body)
            assertEquals(name, expected.getLong("ts"), payload.timestamp)
            assertEquals(name, expected.getString("dk"), payload.dedupKey)
            assertEquals(name, expected.optString("g").ifEmpty { null }, payload.group)
            assertEquals(name, expected.optString("a").ifEmpty { null }, payload.author)
            assertEquals(name, expected.optString("n").ifEmpty { null }, payload.nonce)
            val ids = expected.getJSONObject("ids")
            assertEquals(name, ids.keys().asSequence().toSet(), payload.ids.keys)
            ids.keys().forEach { key -> assertEquals(name, ids.getString(key), payload.ids[key]) }
            // The plaintext travels on to Dart untouched.
            assertArrayEquals(name, case.bytes("plaintext"), payload.json.toByteArray(Charsets.UTF_8))
            assertEquals(name, case.getString("app_dedup_key"), payload.appDedupKey(case.getString("scope")))
        }
    }

    @Test
    fun rejectsEveryPayloadRejectVector() {
        val rejects = PushVectors.cp1.getJSONArray("payload_reject")
        assertTrue(rejects.length() >= 5)
        for (index in 0 until rejects.length()) {
            val reject = rejects.getJSONObject(index)
            assertNull(
                reject.getString("name"),
                PushPayload.parse(reject.getString("plaintext").toByteArray(Charsets.UTF_8)),
            )
        }
    }

    @Test
    fun rejectsInvalidUtf8AndEmptyDedupKeys() {
        assertNull(PushPayload.parse(byteArrayOf(0x7b, 0xc3.toByte(), 0x28, 0x7d)))
        assertNull(parse("""{"v":1,"k":"reply","src":"owui","ids":{},"t":"","b":"","ts":1,"dk":""}"""))
        assertNull(parse("""{"v":"1","k":"reply","src":"owui","ids":{},"t":"","b":"","ts":1,"dk":"x"}"""))
        assertNull(parse(""))
    }

    @Test
    fun ignoresUnknownKeysAndNonStringIds() {
        val payload = parse(
            """{"v":1,"k":"cron","src":"hermes","ids":{"job":"j1","run":7},"t":"T","b":"B",""" +
                """"ts":5,"dk":"cron:j1:7","future":{"x":1}}"""
        )!!
        assertEquals(mapOf("job" to "j1"), payload.ids)
        assertNull(payload.group)
        assertEquals("cron:j1:7", payload.dedupKey)
    }

    @Test
    fun missingOptionalFieldsDefault() {
        val payload = parse("""{"v":1,"k":"reply","dk":"chat:c:m"}""")!!
        assertEquals("", payload.title)
        assertEquals("", payload.body)
        assertEquals(0L, payload.timestamp)
        assertTrue(payload.ids.isEmpty())
    }

    @Test
    fun base64UrlRoundTripsAndRejectsOtherAlphabets() {
        val bytes = ByteArray(256) { it.toByte() }
        for (length in 0..bytes.size) {
            val slice = bytes.copyOf(length)
            val encoded = Base64Url.encode(slice)
            assertTrue(encoded.none { it == '=' || it == '+' || it == '/' })
            assertArrayEquals(slice, Base64Url.decode(encoded))
        }
        assertArrayEquals(byteArrayOf(-5, -1), Base64Url.decode("-_8="))
        listOf("+_8", "/w", "a", "ab c").forEach { text ->
            try {
                Base64Url.decode(text)
                fail("decoded $text")
            } catch (_: IllegalArgumentException) {
                // Expected.
            }
        }
    }

    private fun parse(text: String) = PushPayload.parse(text.toByteArray(Charsets.UTF_8))
}
