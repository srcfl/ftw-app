package energy.ftw.crypto

import com.ionspin.kotlin.bignum.integer.BigInteger
import com.ionspin.kotlin.bignum.integer.Sign

/**
 * IETF ChaCha20-Poly1305 (RFC 8439). Noise encodes its 64-bit counter as a
 * 12-byte nonce: four zero bytes, then the counter little-endian.
 */
object ChaChaPoly {
    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val TAG_BYTES = 16

    fun encrypt(key: ByteArray, nonce: ByteArray, ad: ByteArray, plaintext: ByteArray): ByteArray {
        require(key.size == KEY_BYTES && nonce.size == NONCE_BYTES)
        val otk = block(key, 0, nonce)
        val ciphertext = ByteArray(plaintext.size)
        xorIc(key, nonce, 1, plaintext, ciphertext)
        val tag = poly1305(otk.copyOf(32), ad, ciphertext)
        return ciphertext + tag
    }

    fun decrypt(key: ByteArray, nonce: ByteArray, ad: ByteArray, ciphertextAndTag: ByteArray): ByteArray {
        require(key.size == KEY_BYTES && nonce.size == NONCE_BYTES)
        if (ciphertextAndTag.size < TAG_BYTES) {
            throw NoiseError("authentication failed", "E_NOISE_AUTH")
        }
        val ct = ciphertextAndTag.copyOf(ciphertextAndTag.size - TAG_BYTES)
        val tag = ciphertextAndTag.copyOfRange(ciphertextAndTag.size - TAG_BYTES, ciphertextAndTag.size)
        val otk = block(key, 0, nonce)
        val expect = poly1305(otk.copyOf(32), ad, ct)
        if (!constantTimeEquals(tag, expect)) {
            throw NoiseError("authentication failed", "E_NOISE_AUTH")
        }
        val plaintext = ByteArray(ct.size)
        xorIc(key, nonce, 1, ct, plaintext)
        return plaintext
    }

    private fun quarter(s: IntArray, a: Int, b: Int, c: Int, d: Int) {
        s[a] += s[b]; s[d] = rot(s[d] xor s[a], 16)
        s[c] += s[d]; s[b] = rot(s[b] xor s[c], 12)
        s[a] += s[b]; s[d] = rot(s[d] xor s[a], 8)
        s[c] += s[d]; s[b] = rot(s[b] xor s[c], 7)
    }

    private fun rot(x: Int, n: Int): Int = (x shl n) or (x ushr (32 - n))

    private fun block(key: ByteArray, counter: Int, nonce: ByteArray): ByteArray {
        val s = IntArray(16)
        s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574
        for (i in 0 until 8) s[4 + i] = le32(key, i * 4)
        s[12] = counter
        s[13] = le32(nonce, 0)
        s[14] = le32(nonce, 4)
        s[15] = le32(nonce, 8)
        val w = s.copyOf()
        repeat(10) {
            quarter(w, 0, 4, 8, 12)
            quarter(w, 1, 5, 9, 13)
            quarter(w, 2, 6, 10, 14)
            quarter(w, 3, 7, 11, 15)
            quarter(w, 0, 5, 10, 15)
            quarter(w, 1, 6, 11, 12)
            quarter(w, 2, 7, 8, 13)
            quarter(w, 3, 4, 9, 14)
        }
        val out = ByteArray(64)
        for (i in 0 until 16) putLe32(out, i * 4, w[i] + s[i])
        return out
    }

    private fun xorIc(key: ByteArray, nonce: ByteArray, startCounter: Int, input: ByteArray, output: ByteArray) {
        var counter = startCounter
        var off = 0
        while (off < input.size) {
            val ks = block(key, counter, nonce)
            val n = minOf(64, input.size - off)
            for (i in 0 until n) {
                output[off + i] = (input[off + i].toInt() xor (ks[i].toInt() and 0xff)).toByte()
            }
            off += n
            counter++
        }
    }

    private val P1305: BigInteger = BigInteger.TWO.pow(130) - BigInteger.fromInt(5)
    private val R_CLAMP: BigInteger = BigInteger.parseString("0ffffffc0ffffffc0ffffffc0fffffff", 16)

    private fun poly1305(key: ByteArray, ad: ByteArray, ct: ByteArray): ByteArray {
        val r = fromLe(key.copyOfRange(0, 16)).and(R_CLAMP)
        val s = fromLe(key.copyOfRange(16, 32))
        var acc = BigInteger.ZERO
        fun absorb(chunk: ByteArray) {
            val n = fromLe(chunk + byteArrayOf(1))
            acc = ((acc + n) * r).mod(P1305)
        }
        absorbPadded(ad, ::absorb)
        absorbPadded(ct, ::absorb)
        val lens = ByteArray(16)
        putLe64(lens, 0, ad.size.toLong())
        putLe64(lens, 8, ct.size.toLong())
        absorb(lens)
        acc += s
        val raw = acc.toByteArray()
        val unsigned = if (raw.isNotEmpty() && raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
        val out = ByteArray(16)
        val take = minOf(16, unsigned.size)
        for (i in 0 until take) out[i] = unsigned[unsigned.size - 1 - i]
        return out
    }

    private fun absorbPadded(data: ByteArray, absorb: (ByteArray) -> Unit) {
        if (data.isEmpty()) return
        val pad = (16 - data.size % 16) % 16
        val padded = if (pad == 0) data else data + ByteArray(pad)
        var i = 0
        while (i < padded.size) {
            absorb(padded.copyOfRange(i, i + 16))
            i += 16
        }
    }

    private fun fromLe(b: ByteArray): BigInteger {
        val be = ByteArray(b.size)
        for (i in b.indices) be[b.size - 1 - i] = b[i]
        return BigInteger.fromByteArray(be, Sign.POSITIVE)
    }

    private fun le32(b: ByteArray, off: Int): Int {
        return (b[off].toInt() and 0xff) or
            ((b[off + 1].toInt() and 0xff) shl 8) or
            ((b[off + 2].toInt() and 0xff) shl 16) or
            ((b[off + 3].toInt() and 0xff) shl 24)
    }

    private fun putLe32(b: ByteArray, off: Int, v: Int) {
        b[off] = v.toByte()
        b[off + 1] = (v ushr 8).toByte()
        b[off + 2] = (v ushr 16).toByte()
        b[off + 3] = (v ushr 24).toByte()
    }

    private fun putLe64(b: ByteArray, off: Int, v: Long) {
        for (i in 0 until 8) b[off + i] = (v ushr (8 * i)).toByte()
    }

    private fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var d = 0
        for (i in a.indices) d = d or (a[i].toInt() xor b[i].toInt())
        return d == 0
    }
}

private operator fun ByteArray.plus(other: ByteArray): ByteArray {
    val out = ByteArray(size + other.size)
    copyInto(out)
    other.copyInto(out, size)
    return out
}
