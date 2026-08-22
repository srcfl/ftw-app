package energy.ftw.carrier

enum class CarrierKind { Relay, Cache, None }

sealed class CarrierStatus {
    data object Connecting : CarrierStatus()
    data class Open(val sinceMs: Long) : CarrierStatus()
    data class Closed(val reason: String, val retryable: Boolean) : CarrierStatus()
}

interface Carrier {
    val kind: CarrierKind
    val status: CarrierStatus
    fun send(frame: ByteArray)
    fun onFrame(handler: (ByteArray) -> Unit): () -> Unit
    fun onStatus(handler: (CarrierStatus) -> Unit): () -> Unit
    fun wake() {}
    fun close(reason: String = "closed by client")
}

open class CarrierBase : Carrier {
    override val kind: CarrierKind = CarrierKind.None
    override var status: CarrierStatus = CarrierStatus.Connecting
        protected set

    private val frames = linkedSetOf<(ByteArray) -> Unit>()
    private val statuses = linkedSetOf<(CarrierStatus) -> Unit>()

    override fun send(frame: ByteArray) {}

    override fun onFrame(handler: (ByteArray) -> Unit): () -> Unit {
        frames.add(handler)
        return { frames.remove(handler) }
    }

    override fun onStatus(handler: (CarrierStatus) -> Unit): () -> Unit {
        statuses.add(handler)
        return { statuses.remove(handler) }
    }

    override fun close(reason: String) {
        emitStatus(CarrierStatus.Closed(reason, retryable = false))
        frames.clear()
        statuses.clear()
    }

    protected fun emitFrame(frame: ByteArray) {
        for (h in frames.toList()) {
            try {
                h(frame)
            } catch (_: Throwable) {
            }
        }
    }

    protected fun emitStatus(s: CarrierStatus) {
        status = s
        for (h in statuses.toList()) {
            try {
                h(s)
            } catch (_: Throwable) {
            }
        }
    }
}

interface RawSocket {
    fun sendBinary(bytes: ByteArray)
    fun close()
}

interface SocketListener {
    fun onOpen()
    fun onBinary(bytes: ByteArray)
    fun onText(text: String)
    fun onClose(code: Int, reason: String)
}

fun interface SocketFactory {
    fun open(url: String, listener: SocketListener): RawSocket
}

class LoopbackCarrier : CarrierBase() {
    override val kind = CarrierKind.Relay

    fun peerSend(frame: ByteArray) = emitFrame(frame)

    fun markOpen() = emitStatus(CarrierStatus.Open(nowMs()))

    override fun send(frame: ByteArray) {}
}
