package energy.ftw.identity

/**
 * Base64url, canonical only.
 *
 * The enrollment fragment carries a trust anchor. Two spellings of the same
 * bytes would be two spellings of one anchor, so decoding accepts exactly one
 * form: no padding, no whitespace, no alternate alphabet, and no non-zero bits
 * past the last byte.
 */
class Base64urlError(message: String) : Exception(message)

private const val TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

fun encodeBase64url(bytes: ByteArray): String {
    if (bytes.isEmpty()) return ""
    val out = StringBuilder((bytes.size + 2) / 3 * 4)
    var i = 0
    while (i + 3 <= bytes.size) {
        val n = ((bytes[i].toInt() and 0xff) shl 16) or
            ((bytes[i + 1].toInt() and 0xff) shl 8) or
            (bytes[i + 2].toInt() and 0xff)
        out.append(TABLE[n ushr 18])
        out.append(TABLE[(n ushr 12) and 63])
        out.append(TABLE[(n ushr 6) and 63])
        out.append(TABLE[n and 63])
        i += 3
    }
    val rem = bytes.size - i
    if (rem == 1) {
        val n = (bytes[i].toInt() and 0xff) shl 16
        out.append(TABLE[n ushr 18])
        out.append(TABLE[(n ushr 12) and 63])
    } else if (rem == 2) {
        val n = ((bytes[i].toInt() and 0xff) shl 16) or ((bytes[i + 1].toInt() and 0xff) shl 8)
        out.append(TABLE[n ushr 18])
        out.append(TABLE[(n ushr 12) and 63])
        out.append(TABLE[(n ushr 6) and 63])
    }
    return out.toString()
}

fun decodeBase64url(text: String): ByteArray {
    for (c in text) {
        if (c !in 'A'..'Z' && c !in 'a'..'z' && c !in '0'..'9' && c != '-' && c != '_') {
            throw Base64urlError("character outside the base64url alphabet")
        }
    }
    if (text.length % 4 == 1) {
        throw Base64urlError("length ${text.length} cannot encode whole bytes")
    }
    if (text.isEmpty()) return ByteArray(0)

    val full = text.length / 4
    val rem = text.length % 4
    val outLen = full * 3 + when (rem) {
        0 -> 0
        2 -> 1
        3 -> 2
        else -> throw Base64urlError("length ${text.length} cannot encode whole bytes")
    }
    val out = ByteArray(outLen)
    var ti = 0
    var oi = 0
    repeat(full) {
        val n = (idx(text[ti]) shl 18) or (idx(text[ti + 1]) shl 12) or
            (idx(text[ti + 2]) shl 6) or idx(text[ti + 3])
        out[oi] = (n ushr 16).toByte()
        out[oi + 1] = (n ushr 8).toByte()
        out[oi + 2] = n.toByte()
        ti += 4
        oi += 3
    }
    if (rem == 2) {
        val n = (idx(text[ti]) shl 18) or (idx(text[ti + 1]) shl 12)
        out[oi] = (n ushr 16).toByte()
    } else if (rem == 3) {
        val n = (idx(text[ti]) shl 18) or (idx(text[ti + 1]) shl 12) or (idx(text[ti + 2]) shl 6)
        out[oi] = (n ushr 16).toByte()
        out[oi + 1] = (n ushr 8).toByte()
    }

    if (encodeBase64url(out) != text) {
        throw Base64urlError("not canonical: bits past the final byte are set")
    }
    return out
}

private fun idx(c: Char): Int {
    val i = TABLE.indexOf(c)
    if (i < 0) throw Base64urlError("character outside the base64url alphabet")
    return i
}
