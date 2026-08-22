package energy.ftw.crypto

/** SHA-256. Spec: FIPS 180-4. */
object Sha256 {
    fun hash(data: ByteArray): ByteArray {
        val h = intArrayOf(
            0x6a09e667, 0xbb67ae85.toInt(), 0x3c6ef372, 0xa54ff53a.toInt(),
            0x510e527f, 0x9b05688c.toInt(), 0x1f83d9ab, 0x5be0cd19,
        )
        val bitLen = data.size.toLong() * 8
        val withOne = data.size + 1
        val pad = (64 - ((withOne + 8) % 64)) % 64
        val block = ByteArray(withOne + pad + 8)
        data.copyInto(block)
        block[data.size] = 0x80.toByte()
        for (i in 0 until 8) {
            block[block.size - 1 - i] = ((bitLen ushr (8 * i)) and 0xff).toByte()
        }
        val w = IntArray(64)
        var off = 0
        while (off < block.size) {
            for (i in 0 until 16) {
                val j = off + i * 4
                w[i] = ((block[j].toInt() and 0xff) shl 24) or
                    ((block[j + 1].toInt() and 0xff) shl 16) or
                    ((block[j + 2].toInt() and 0xff) shl 8) or
                    (block[j + 3].toInt() and 0xff)
            }
            for (i in 16 until 64) {
                val s0 = rot(w[i - 15], 7) xor rot(w[i - 15], 18) xor (w[i - 15] ushr 3)
                val s1 = rot(w[i - 2], 17) xor rot(w[i - 2], 19) xor (w[i - 2] ushr 10)
                w[i] = w[i - 16] + s0 + w[i - 7] + s1
            }
            var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
            var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
            for (i in 0 until 64) {
                val S1 = rot(e, 6) xor rot(e, 11) xor rot(e, 25)
                val ch = (e and f) xor (e.inv() and g)
                val t1 = hh + S1 + ch + K[i] + w[i]
                val S0 = rot(a, 2) xor rot(a, 13) xor rot(a, 22)
                val maj = (a and b) xor (a and c) xor (b and c)
                val t2 = S0 + maj
                hh = g; g = f; f = e; e = d + t1
                d = c; c = b; b = a; a = t1 + t2
            }
            h[0] += a; h[1] += b; h[2] += c; h[3] += d
            h[4] += e; h[5] += f; h[6] += g; h[7] += hh
            off += 64
        }
        val out = ByteArray(32)
        for (i in 0 until 8) {
            val v = h[i]
            out[i * 4] = (v ushr 24).toByte()
            out[i * 4 + 1] = (v ushr 16).toByte()
            out[i * 4 + 2] = (v ushr 8).toByte()
            out[i * 4 + 3] = v.toByte()
        }
        return out
    }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val k = if (key.size > 64) hash(key) else key
        val ipad = ByteArray(64) { i -> (((if (i < k.size) k[i].toInt() else 0) xor 0x36) and 0xff).toByte() }
        val opad = ByteArray(64) { i -> (((if (i < k.size) k[i].toInt() else 0) xor 0x5c) and 0xff).toByte() }
        return hash(opad + hash(ipad + data))
    }

    private fun rot(x: Int, n: Int): Int = (x ushr n) or (x shl (32 - n))

    private val K = intArrayOf(
        0x428a2f98, 0x71374491, 0xb5c0fbcf.toInt(), 0xe9b5dba5.toInt(),
        0x3956c25b, 0x59f111f1, 0x923f82a4.toInt(), 0xab1c5ed5.toInt(),
        0xd807aa98.toInt(), 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe.toInt(), 0x9bdc06a7.toInt(), 0xc19bf174.toInt(),
        0xe49b69c1.toInt(), 0xefbe4786.toInt(), 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152.toInt(), 0xa831c66d.toInt(), 0xb00327c8.toInt(), 0xbf597fc7.toInt(),
        0xc6e00bf3.toInt(), 0xd5a79147.toInt(), 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e.toInt(), 0x92722c85.toInt(),
        0xa2bfe8a1.toInt(), 0xa81a664b.toInt(), 0xc24b8b70.toInt(), 0xc76c51a3.toInt(),
        0xd192e819.toInt(), 0xd6990624.toInt(), 0xf40e3585.toInt(), 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814.toInt(), 0x8cc70208.toInt(),
        0x90befffa.toInt(), 0xa4506ceb.toInt(), 0xbef9a3f7.toInt(), 0xc67178f2.toInt(),
    )
}

private operator fun ByteArray.plus(other: ByteArray): ByteArray {
    val out = ByteArray(size + other.size)
    copyInto(out)
    other.copyInto(out, size)
    return out
}
