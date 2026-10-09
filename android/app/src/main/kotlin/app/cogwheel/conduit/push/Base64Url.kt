package app.cogwheel.conduit.push

/**
 * Base64url without padding (RFC 4648 section 5), the encoding of every key,
 * secret and body in the push protocol.
 *
 * `java.util.Base64` needs API 26 and `android.util.Base64` is missing from
 * JVM unit tests, so the push code carries its own.
 */
internal object Base64Url {
    private const val ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    private val DECODE = IntArray(128) { -1 }.also { table ->
        ALPHABET.forEachIndexed { index, char -> table[char.code] = index }
    }

    fun encode(bytes: ByteArray): String {
        val out = StringBuilder((bytes.size * 4 + 2) / 3)
        var i = 0
        while (i + 3 <= bytes.size) {
            val n = (bytes[i].toInt() and 0xff shl 16) or
                (bytes[i + 1].toInt() and 0xff shl 8) or
                (bytes[i + 2].toInt() and 0xff)
            out.append(ALPHABET[n ushr 18 and 63])
            out.append(ALPHABET[n ushr 12 and 63])
            out.append(ALPHABET[n ushr 6 and 63])
            out.append(ALPHABET[n and 63])
            i += 3
        }
        when (bytes.size - i) {
            1 -> {
                val n = bytes[i].toInt() and 0xff shl 16
                out.append(ALPHABET[n ushr 18 and 63])
                out.append(ALPHABET[n ushr 12 and 63])
            }
            2 -> {
                val n = (bytes[i].toInt() and 0xff shl 16) or (bytes[i + 1].toInt() and 0xff shl 8)
                out.append(ALPHABET[n ushr 18 and 63])
                out.append(ALPHABET[n ushr 12 and 63])
                out.append(ALPHABET[n ushr 6 and 63])
            }
        }
        return out.toString()
    }

    /**
     * Decodes base64url, with or without `=` padding. Standard base64's `+`
     * and `/` are rejected, as is anything else outside the alphabet.
     *
     * @throws IllegalArgumentException when [text] is not base64url.
     */
    fun decode(text: String): ByteArray {
        val trimmed = text.trimEnd('=')
        require(trimmed.length % 4 != 1) { "Invalid base64url length" }
        val out = ByteArray(trimmed.length * 3 / 4)
        var buffer = 0
        var bits = 0
        var index = 0
        for (char in trimmed) {
            val value = if (char.code < 128) DECODE[char.code] else -1
            require(value >= 0) { "Invalid base64url character" }
            buffer = (buffer shl 6) or value
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out[index++] = (buffer ushr bits and 0xff).toByte()
            }
        }
        return out
    }
}
