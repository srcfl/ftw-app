package energy.ftw.crypto

const val SEQ_BYTES = 8
const val TRANSPORT_OVERHEAD = SEQ_BYTES + TAG_BYTES
const val REPLAY_WINDOW = 64

class NoiseTransport(result: HandshakeResult) {
    val handshakeHash: ByteArray = result.handshakeHash
    val remoteStatic: ByteArray = result.remoteStatic
    private val send = result.send
    private val recv = result.recv
    private var highestSeq = -1L
    private var seen = 0L
    private var closed = false

    val nextSeq: Long get() = send.nonce

    fun encrypt(frame: ByteArray): ByteArray {
        assertOpen()
        val seq = writeSeq(send.nonce)
        val body = send.encryptWithAd(seq, frame)
        return concatSeq(seq, body)
    }

    fun decrypt(bytes: ByteArray): ByteArray {
        assertOpen()
        if (bytes.size < TRANSPORT_OVERHEAD) {
            throw NoiseError("transport message is ${bytes.size} bytes", "E_NOISE_MESSAGE")
        }
        val seqBytes = bytes.copyOfRange(0, SEQ_BYTES)
        val seq = readSeq(seqBytes)
        checkReplay(seq)
        recv.setNonce(seq)
        val frame = recv.decryptWithAd(seqBytes, bytes.copyOfRange(SEQ_BYTES, bytes.size))
        markSeen(seq)
        return frame
    }

    fun close() {
        closed = true
        send.destroy()
        recv.destroy()
    }

    private fun assertOpen() {
        if (closed) throw NoiseError("session is closed", "E_NOISE_CLOSED")
    }

    private fun checkReplay(seq: Long) {
        if (seq > highestSeq) return
        val behind = highestSeq - seq
        if (behind >= REPLAY_WINDOW) {
            throw NoiseError("sequence $seq is outside the replay window", "E_NOISE_REPLAY")
        }
        if (((seen ushr behind.toInt()) and 1L) == 1L) {
            throw NoiseError("sequence $seq was already accepted", "E_NOISE_REPLAY")
        }
    }

    private fun markSeen(seq: Long) {
        if (seq > highestSeq) {
            val shift = seq - highestSeq
            seen = if (shift >= REPLAY_WINDOW) 1L else ((seen shl shift.toInt()) or 1L) and WINDOW_MASK
            highestSeq = seq
        } else {
            seen = seen or (1L shl (highestSeq - seq).toInt())
        }
    }

    companion object {
        private const val WINDOW_MASK = (1L shl REPLAY_WINDOW) - 1L
    }
}

private fun writeSeq(seq: Long): ByteArray {
    val out = ByteArray(SEQ_BYTES)
    var v = seq
    for (i in SEQ_BYTES - 1 downTo 0) {
        out[i] = (v and 0xff).toByte()
        v = v ushr 8
    }
    return out
}

private fun readSeq(bytes: ByteArray): Long {
    var v = 0L
    for (i in 0 until SEQ_BYTES) v = (v shl 8) or (bytes[i].toLong() and 0xff)
    return v
}

private fun concatSeq(seq: ByteArray, body: ByteArray): ByteArray {
    val out = ByteArray(seq.size + body.size)
    seq.copyInto(out)
    body.copyInto(out, seq.size)
    return out
}
