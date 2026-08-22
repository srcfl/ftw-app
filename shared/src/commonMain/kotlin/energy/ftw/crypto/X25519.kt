package energy.ftw.crypto

import com.ionspin.kotlin.bignum.integer.BigInteger

/**
 * X25519 from RFC 7748. Big-integer ladder so the field matches every other
 * client; the Cacophony vector is the proof, not this comment.
 */
object X25519 {
    const val BYTES = 32

    private val P: BigInteger = BigInteger.parseString(
        "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed",
        16,
    )
    private val A24: BigInteger = BigInteger.fromInt(121665)
    private val TWO: BigInteger = BigInteger.TWO
    private val BASE_U = decodeU(ByteArray(32).also { it[0] = 9 })

    fun publicKey(secret: ByteArray): ByteArray {
        require(secret.size == BYTES)
        return encodeU(ladder(decodeScalar(secret), BASE_U))
    }

    fun sharedSecret(secret: ByteArray, peerPublic: ByteArray): ByteArray {
        require(secret.size == BYTES && peerPublic.size == BYTES)
        val out = encodeU(ladder(decodeScalar(secret), decodeU(peerPublic)))
        if (out.all { it == 0.toByte() }) {
            throw NoiseError("X25519 low-order point", "E_NOISE_DH")
        }
        return out
    }

    private fun ladder(k: BigInteger, u: BigInteger): BigInteger {
        var x1 = u
        var x2 = BigInteger.ONE
        var z2 = BigInteger.ZERO
        var x3 = u
        var z3 = BigInteger.ONE
        var swap = 0
        for (t in 254 downTo 0) {
            val kt = if (k.bitAt(t.toLong())) 1 else 0
            swap = swap xor kt
            cswap(swap, x2, x3).let { x2 = it.first; x3 = it.second }
            cswap(swap, z2, z3).let { z2 = it.first; z3 = it.second }
            swap = kt

            val a = add(x2, z2)
            val aa = sq(a)
            val b = sub(x2, z2)
            val bb = sq(b)
            val e = sub(aa, bb)
            val c = add(x3, z3)
            val d = sub(x3, z3)
            val da = mul(d, a)
            val cb = mul(c, b)
            x3 = sq(add(da, cb))
            z3 = mul(x1, sq(sub(da, cb)))
            x2 = mul(aa, bb)
            z2 = mul(e, add(aa, mul(A24, e)))
        }
        cswap(swap, x2, x3).let { x2 = it.first; x3 = it.second }
        cswap(swap, z2, z3).let { z2 = it.first; z3 = it.second }
        return mul(x2, z2.modInverse(P))
    }

    private fun add(a: BigInteger, b: BigInteger) = (a + b).mod(P)
    private fun sub(a: BigInteger, b: BigInteger) = (a - b).mod(P)
    private fun mul(a: BigInteger, b: BigInteger) = (a * b).mod(P)
    private fun sq(a: BigInteger) = mul(a, a)

    private fun cswap(swap: Int, a: BigInteger, b: BigInteger): Pair<BigInteger, BigInteger> {
        return if (swap == 1) Pair(b, a) else Pair(a, b)
    }

    private fun decodeScalar(k: ByteArray): BigInteger {
        val c = k.copyOf()
        c[0] = (c[0].toInt() and 248).toByte()
        c[31] = ((c[31].toInt() and 127) or 64).toByte()
        return fromLe(c)
    }

    private fun decodeU(u: ByteArray): BigInteger {
        val c = u.copyOf()
        c[31] = (c[31].toInt() and 127).toByte()
        return fromLe(c).mod(P)
    }

    private fun encodeU(u: BigInteger): ByteArray {
        var x = u.mod(P)
        val out = ByteArray(32)
        val mask = BigInteger.fromInt(255)
        for (i in 0 until 32) {
            out[i] = (x and mask).intValue().toByte()
            x = x shr 8
        }
        return out
    }

    private fun fromLe(b: ByteArray): BigInteger {
        var n = BigInteger.ZERO
        for (i in b.size - 1 downTo 0) {
            n = (n shl 8) + BigInteger.fromInt(b[i].toInt() and 0xff)
        }
        return n
    }
}
