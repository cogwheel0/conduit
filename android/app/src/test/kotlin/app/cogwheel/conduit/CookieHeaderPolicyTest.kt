package app.cogwheel.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CookieHeaderPolicyTest {
    @Test
    fun duplicateCookieNamesKeepTheFirstMoreSpecificValue() {
        val cookies = cookieValuesFromHeader(
            "session=scoped; tenant=one; session=root"
        )

        assertEquals("scoped", cookies["session"])
        assertEquals("one", cookies["tenant"])
    }

    @Test
    fun malformedAndEmptyCookieNamesAreIgnored() {
        val cookies = cookieValuesFromHeader("broken; =secret; valid=value=with=equals")

        assertFalse(cookies.containsKey(""))
        assertFalse(cookies.containsKey("broken"))
        assertEquals("value=with=equals", cookies["valid"])
    }
}
