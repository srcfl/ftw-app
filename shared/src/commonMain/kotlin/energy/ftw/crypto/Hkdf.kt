package energy.ftw.crypto

/**
 * HKDF-SHA256. Extract uses [salt] (chaining key in Noise); expand uses [info].
 * Splitting `outputs * 32` off a single expand is byte-identical to Noise's
 * chained HMAC construction.
 */
object Hkdf {
    fun extract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val s = if (salt.isEmpty()) ByteArray(32) else salt
        return Sha256.hmac(s, ikm)
    }

    fun expand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val out = ByteArray(length)
        var t = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            t = Sha256.hmac(prk, t + info + byteArrayOf(counter.toByte()))
            val n = minOf(t.size, length - written)
            t.copyInto(out, written, 0, n)
            written += n
            counter++
        }
        return out
    }

    fun extractExpand(salt: ByteArray, ikm: ByteArray, info: ByteArray, length: Int): ByteArray =
        expand(extract(salt, ikm), info, length)
}

private operator fun ByteArray.plus(other: ByteArray): ByteArray {
    val out = ByteArray(size + other.size)
    copyInto(out)
    other.copyInto(out, size)
    return out
}
