package energy.ftw.protocol

/**
 * Minimal CBOR for FTW envelopes: maps with text keys, ints, text, bytes,
 * arrays, bool, null. Encode uses the caller's key order — the TypeScript
 * client encodes insertion order, not canonical sort.
 */
sealed class Cbor {
    data class Map(val entries: List<Pair<String, Cbor>>) : Cbor() {
        operator fun get(key: String): Cbor? = entries.firstOrNull { it.first == key }?.second
        fun text(key: String): String? = (this[key] as? Txt)?.value
        fun long(key: String): Long? = (this[key] as? Num)?.value
        fun bool(key: String): Boolean? = (this[key] as? Bool)?.value
        fun map(key: String): Map? = this[key] as? Map
        fun list(key: String): Arr? = this[key] as? Arr
    }
    data class Arr(val items: List<Cbor>) : Cbor()
    data class Txt(val value: String) : Cbor()
    data class Bytes(val value: ByteArray) : Cbor() {
        override fun equals(other: Any?) = other is Bytes && value.contentEquals(other.value)
        override fun hashCode() = value.contentHashCode()
    }
    data class Num(val value: Long) : Cbor()
    data class Bool(val value: Boolean) : Cbor()
    data object Null : Cbor()

    companion object {
        fun map(vararg pairs: Pair<String, Cbor>) = Map(pairs.toList())
        fun txt(s: String) = Txt(s)
        fun num(n: Long) = Num(n)
        fun num(n: Int) = Num(n.toLong())
        fun arr(vararg items: Cbor) = Arr(items.toList())
        fun bytes(b: ByteArray) = Bytes(b)
    }
}

fun encodeCbor(value: Cbor): ByteArray {
    val out = ArrayList<Byte>(64)
    write(out, value)
    return out.toByteArray()
}

fun decodeCbor(bytes: ByteArray): Cbor {
    val r = Reader(bytes)
    val v = r.read()
    return v
}

private fun write(out: ArrayList<Byte>, v: Cbor) {
    when (v) {
        is Cbor.Null -> out.add(0xf6.toByte())
        is Cbor.Bool -> out.add(if (v.value) 0xf5.toByte() else 0xf4.toByte())
        is Cbor.Num -> writeInt(out, v.value)
        is Cbor.Txt -> {
            val u = v.value.encodeToByteArray()
            writeLen(out, 3, u.size)
            u.forEach { out.add(it) }
        }
        is Cbor.Bytes -> {
            writeLen(out, 2, v.value.size)
            v.value.forEach { out.add(it) }
        }
        is Cbor.Arr -> {
            writeLen(out, 4, v.items.size)
            v.items.forEach { write(out, it) }
        }
        is Cbor.Map -> {
            writeLen(out, 5, v.entries.size)
            for ((k, value) in v.entries) {
                write(out, Cbor.Txt(k))
                write(out, value)
            }
        }
    }
}

private fun writeInt(out: ArrayList<Byte>, n: Long) {
    if (n >= 0) writeHead(out, 0, n) else writeHead(out, 1, -1 - n)
}

private fun writeLen(out: ArrayList<Byte>, major: Int, len: Int) {
    writeHead(out, major, len.toLong())
}

private fun writeHead(out: ArrayList<Byte>, major: Int, n: Long) {
    val hi = (major shl 5).toByte()
    when {
        n < 24 -> out.add((hi.toInt() or n.toInt()).toByte())
        n < 256 -> {
            out.add((hi.toInt() or 24).toByte())
            out.add(n.toByte())
        }
        n < 65536 -> {
            out.add((hi.toInt() or 25).toByte())
            out.add((n ushr 8).toByte())
            out.add(n.toByte())
        }
        n < (1L shl 32) -> {
            out.add((hi.toInt() or 26).toByte())
            out.add((n ushr 24).toByte())
            out.add((n ushr 16).toByte())
            out.add((n ushr 8).toByte())
            out.add(n.toByte())
        }
        else -> {
            out.add((hi.toInt() or 27).toByte())
            for (i in 7 downTo 0) out.add((n ushr (8 * i)).toByte())
        }
    }
}

private class Reader(val bytes: ByteArray) {
    var i = 0
    fun read(): Cbor {
        val ib = u8()
        val major = ib ushr 5
        val addl = ib and 0x1f
        val n = argument(addl)
        return when (major) {
            0 -> Cbor.Num(n)
            1 -> Cbor.Num(-1 - n)
            2 -> Cbor.Bytes(take(n.toInt()))
            3 -> Cbor.Txt(take(n.toInt()).decodeToString())
            4 -> Cbor.Arr((0 until n.toInt()).map { read() })
            5 -> {
                val entries = ArrayList<Pair<String, Cbor>>(n.toInt())
                repeat(n.toInt()) {
                    val k = (read() as Cbor.Txt).value
                    entries.add(k to read())
                }
                Cbor.Map(entries)
            }
            7 -> when (addl) {
                20 -> Cbor.Bool(false)
                21 -> Cbor.Bool(true)
                22 -> Cbor.Null
                else -> throw CborError("unsupported simple $addl")
            }
            else -> throw CborError("unsupported major $major")
        }
    }

    private fun argument(addl: Int): Long = when {
        addl < 24 -> addl.toLong()
        addl == 24 -> u8().toLong()
        addl == 25 -> ((u8().toLong() shl 8) or u8().toLong())
        addl == 26 -> {
            var v = 0L
            repeat(4) { v = (v shl 8) or u8().toLong() }
            v
        }
        addl == 27 -> {
            var v = 0L
            repeat(8) { v = (v shl 8) or u8().toLong() }
            v
        }
        else -> throw CborError("indefinite CBOR is not used on this wire")
    }

    private fun u8(): Int {
        if (i >= bytes.size) throw CborError("truncated CBOR")
        return bytes[i++].toInt() and 0xff
    }

    private fun take(n: Int): ByteArray {
        if (i + n > bytes.size) throw CborError("truncated CBOR")
        val s = bytes.copyOfRange(i, i + n)
        i += n
        return s
    }
}

class CborError(message: String) : Exception(message)
