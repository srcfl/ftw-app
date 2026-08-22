package energy.ftw.carrier

import energy.ftw.crypto.HandshakeState
import energy.ftw.crypto.KeyPair
import energy.ftw.crypto.MESSAGE_2_OVERHEAD
import energy.ftw.crypto.NoiseError
import energy.ftw.crypto.NoiseTransport

class NoiseCarrier(
    private val inner: Carrier,
    private val staticKey: KeyPair,
    private val remoteStatic: ByteArray,
    private val prologue: ByteArray,
    private val handshakePayload: ByteArray = ByteArray(0),
) : CarrierBase() {
    override val kind = inner.kind

    private var handshake: HandshakeState? = null
    private var transport: NoiseTransport? = null
    private var awaitingReply = false
    private var closed = false
    private val unsub = mutableListOf<() -> Unit>()

    init {
        unsub += inner.onFrame { onInnerFrame(it) }
        unsub += inner.onStatus { onInnerStatus(it) }
        if (inner.status is CarrierStatus.Open) beginHandshake()
    }

    override fun send(frame: ByteArray) {
        val t = transport ?: return
        if (status !is CarrierStatus.Open) return
        try {
            inner.send(t.encrypt(frame))
        } catch (_: NoiseError) {
            fail("encryption failed", retryable = false)
        }
    }

    override fun wake() {
        if (closed) return
        resetSession()
        emitStatus(CarrierStatus.Closed("reconnecting after wake", retryable = true))
        inner.wake()
        if (inner.status is CarrierStatus.Open) beginHandshake()
    }

    override fun close(reason: String) {
        if (closed) return
        closed = true
        unsub.forEach { it() }
        unsub.clear()
        resetSession()
        inner.close(reason)
        super.close(reason)
    }

    private fun onInnerStatus(s: CarrierStatus) {
        if (closed) return
        if (s is CarrierStatus.Open) {
            beginHandshake()
            return
        }
        resetSession()
        emitStatus(s)
    }

    private fun beginHandshake() {
        if (closed || awaitingReply || transport != null) return
        val hs = HandshakeState.initiator(staticKey, remoteStatic, prologue)
        handshake = hs
        awaitingReply = true
        emitStatus(CarrierStatus.Connecting)
        try {
            inner.send(hs.writeMessage(handshakePayload))
        } catch (e: NoiseError) {
            fail(e.message ?: "handshake failed")
        }
    }

    private fun onInnerFrame(bytes: ByteArray) {
        if (closed) return
        if (awaitingReply) {
            if (bytes.size == MESSAGE_2_OVERHEAD) completeHandshake(bytes)
            return
        }
        val t = transport ?: return
        try {
            emitFrame(t.decrypt(bytes))
        } catch (e: NoiseError) {
            if (e.code == "E_NOISE_AUTH" || e.code == "E_NOISE_REPLAY" || e.code == "E_NOISE_MESSAGE") return
            throw e
        }
    }

    private fun completeHandshake(bytes: ByteArray) {
        val hs = handshake ?: return
        try {
            hs.readMessage(bytes)
        } catch (_: NoiseError) {
            return
        }
        transport = NoiseTransport(hs.split())
        awaitingReply = false
        handshake = null
        emitStatus(CarrierStatus.Open(nowMs()))
    }

    private fun resetSession() {
        transport?.close()
        transport = null
        handshake = null
        awaitingReply = false
    }

    private fun fail(reason: String, retryable: Boolean = true) {
        if (closed) return
        resetSession()
        emitStatus(CarrierStatus.Closed(reason, retryable))
    }
}
