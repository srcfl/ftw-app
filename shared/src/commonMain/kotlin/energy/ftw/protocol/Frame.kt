package energy.ftw.protocol

const val FRAME_VERSION = 1
const val HEADER_BYTES = 6
const val MAX_PAYLOAD = 0xffff
const val LANE_CONTROL = 0
const val LANE_BULK = 1
const val FLAG_TRUNC = 0x02
const val CONTROL_BUCKET = 512

data class Envelope(val t: String, val id: Long? = null, val b: Cbor? = null)

data class Frame(val lane: Int, val flags: Int, val envelope: Envelope)

class FrameError(message: String, val code: String) : Exception(message)

fun encodeFrame(frame: Frame, bucket: Int = CONTROL_BUCKET): ByteArray {
    val payload = encodeCbor(
        Cbor.map(
            *buildList {
                add("t" to Cbor.txt(frame.envelope.t))
                frame.envelope.id?.let { add("id" to Cbor.num(it)) }
                frame.envelope.b?.let { add("b" to it) }
            }.toTypedArray(),
        ),
    )
    if (payload.size > MAX_PAYLOAD) {
        throw FrameError("payload ${payload.size} exceeds u16 length field", "E_FRAME_TOO_LARGE")
    }
    val needed = HEADER_BYTES + payload.size
    if (needed > bucket) {
        throw FrameError("frame needs $needed bytes, bucket is $bucket", "E_FRAME_EXCEEDS_BUCKET")
    }
    val out = ByteArray(bucket)
    out[0] = FRAME_VERSION.toByte()
    out[1] = frame.lane.toByte()
    out[2] = frame.flags.toByte()
    out[3] = 0
    out[4] = (payload.size ushr 8).toByte()
    out[5] = payload.size.toByte()
    payload.copyInto(out, HEADER_BYTES)
    return out
}

fun decodeFrame(bytes: ByteArray): Frame {
    if (bytes.size < HEADER_BYTES) {
        throw FrameError("frame is ${bytes.size} bytes, need at least $HEADER_BYTES", "E_FRAME_SHORT")
    }
    val ver = bytes[0].toInt() and 0xff
    if (ver != FRAME_VERSION) {
        throw FrameError("unsupported frame version $ver", "E_FRAME_VERSION")
    }
    val lane = bytes[1].toInt() and 0xff
    val flags = bytes[2].toInt() and 0xff
    val len = ((bytes[4].toInt() and 0xff) shl 8) or (bytes[5].toInt() and 0xff)
    if (HEADER_BYTES + len > bytes.size) {
        throw FrameError("declared length $len overruns the ${bytes.size}-byte frame", "E_FRAME_TRUNCATED")
    }
    val payload = bytes.copyOfRange(HEADER_BYTES, HEADER_BYTES + len)
    val decoded = try {
        decodeCbor(payload)
    } catch (e: CborError) {
        throw FrameError("payload is not valid CBOR: ${e.message}", "E_FRAME_CBOR")
    }
    val map = decoded as? Cbor.Map ?: throw FrameError("envelope must be a CBOR map", "E_FRAME_ENVELOPE")
    val t = map.text("t") ?: throw FrameError("envelope is missing a string type", "E_FRAME_ENVELOPE")
    val id = map.long("id")
    val b = map["b"]
    return Frame(lane, flags, Envelope(t, id, b))
}

fun isTruncated(frame: Frame): Boolean = (frame.flags and FLAG_TRUNC) != 0
