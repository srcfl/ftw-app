package energy.ftw

fun concat(vararg parts: ByteArray): ByteArray {
    val n = parts.sumOf { it.size }
    val out = ByteArray(n)
    var at = 0
    for (p in parts) {
        p.copyInto(out, at)
        at += p.size
    }
    return out
}

fun ByteArray.toHex(): String {
    val chars = CharArray(size * 2)
    var i = 0
    for (b in this) {
        val v = b.toInt() and 0xff
        chars[i++] = HEX[v ushr 4]
        chars[i++] = HEX[v and 0x0f]
    }
    return chars.concatToString()
}

fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "odd hex length" }
    val out = ByteArray(length / 2)
    var i = 0
    while (i < length) {
        val hi = hexNibble(this[i])
        val lo = hexNibble(this[i + 1])
        out[i / 2] = ((hi shl 4) or lo).toByte()
        i += 2
    }
    return out
}

private val HEX = "0123456789abcdef".toCharArray()

private fun hexNibble(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    in 'A'..'F' -> c - 'A' + 10
    else -> throw IllegalArgumentException("not hex: $c")
}

fun ByteArray.contentEqualsOrEmpty(other: ByteArray): Boolean = contentEquals(other)

fun utf8(s: String): ByteArray = s.encodeToByteArray()
