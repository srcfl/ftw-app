package energy.ftw.crypto

import energy.ftw.concat

const val PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256"
const val DH_BYTES = 32
const val KEY_BYTES = 32
const val HASH_BYTES = 32
const val TAG_BYTES = 16
const val MESSAGE_1_OVERHEAD = DH_BYTES + DH_BYTES + TAG_BYTES + TAG_BYTES
const val MESSAGE_2_OVERHEAD = DH_BYTES + TAG_BYTES

private val MAX_NONCE = (1L shl 62) // stay inside signed Long; 2^64-1 is the spec cap

class NoiseError(message: String, val code: String) : Exception(message)

data class KeyPair(val secretKey: ByteArray, val publicKey: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (other !is KeyPair) return false
        return secretKey.contentEquals(other.secretKey) && publicKey.contentEquals(other.publicKey)
    }
    override fun hashCode() = secretKey.contentHashCode() * 31 + publicKey.contentHashCode()
}

fun generateKeyPair(): KeyPair {
    val secret = randomBytes(DH_BYTES)
    return KeyPair(secret, X25519.publicKey(secret))
}

fun keyPairFromSecret(secretKey: ByteArray): KeyPair {
    if (secretKey.size != DH_BYTES) {
        throw NoiseError("static key is ${secretKey.size} bytes, need $DH_BYTES", "E_NOISE_KEY")
    }
    return KeyPair(secretKey, X25519.publicKey(secretKey))
}

private fun dh(secretKey: ByteArray, publicKey: ByteArray): ByteArray =
    X25519.sharedSecret(secretKey, publicKey)

private fun hkdfN(chainingKey: ByteArray, ikm: ByteArray, outputs: Int): List<ByteArray> {
    val prk = Hkdf.extract(chainingKey, ikm)
    val okm = Hkdf.expand(prk, ByteArray(0), outputs * HASH_BYTES)
    return (0 until outputs).map { i -> okm.copyOfRange(i * HASH_BYTES, (i + 1) * HASH_BYTES) }
}

private fun nonceBytes(n: Long): ByteArray {
    val out = ByteArray(12)
    var v = n
    for (i in 4 until 12) {
        out[i] = (v and 0xff).toByte()
        v = v ushr 8
    }
    return out
}

class CipherState(key: ByteArray? = null) {
    private var key: ByteArray? = key?.copyOf()
    var nonce: Long = 0
        private set
    private var destroyed = false

    val hasKey: Boolean get() = key != null

    fun setNonce(n: Long) {
        if (n < 0 || n >= MAX_NONCE) {
            throw NoiseError("nonce $n is out of range", "E_NOISE_NONCE_EXHAUSTED")
        }
        nonce = n
    }

    fun encryptWithAd(ad: ByteArray, plaintext: ByteArray): ByteArray {
        assertUsable()
        val k = key ?: return plaintext
        val n = take()
        return ChaChaPoly.encrypt(k, nonceBytes(n), ad, plaintext)
    }

    fun decryptWithAd(ad: ByteArray, ciphertext: ByteArray): ByteArray {
        assertUsable()
        val k = key ?: return ciphertext
        val n = take()
        try {
            return ChaChaPoly.decrypt(k, nonceBytes(n), ad, ciphertext)
        } catch (e: NoiseError) {
            throw if (e.code == "E_NOISE_AUTH") e else NoiseError("authentication failed", "E_NOISE_AUTH")
        }
    }

    fun clone(): CipherState {
        val copy = CipherState(key)
        copy.nonce = nonce
        copy.destroyed = destroyed
        return copy
    }

    fun destroy() {
        key?.fill(0)
        key = null
        destroyed = true
    }

    private fun assertUsable() {
        if (destroyed) throw NoiseError("cipher was destroyed", "E_NOISE_CLOSED")
    }

    private fun take(): Long {
        if (nonce >= MAX_NONCE) throw NoiseError("nonce space exhausted", "E_NOISE_NONCE_EXHAUSTED")
        val n = nonce
        nonce++
        return n
    }
}

private class SymmetricState {
    var ck: ByteArray
    var h: ByteArray
    var cipher = CipherState()

    init {
        val name = PROTOCOL_NAME.encodeToByteArray()
        h = if (name.size <= HASH_BYTES) {
            concat(name, ByteArray(HASH_BYTES - name.size))
        } else {
            Sha256.hash(name)
        }
        ck = h.copyOf()
    }

    fun mixHash(data: ByteArray) {
        h = Sha256.hash(concat(h, data))
    }

    fun mixKey(ikm: ByteArray) {
        val parts = hkdfN(ck, ikm, 2)
        ck = parts[0]
        cipher = CipherState(parts[1])
    }

    fun encryptAndHash(plaintext: ByteArray): ByteArray {
        val ciphertext = cipher.encryptWithAd(h, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    fun decryptAndHash(ciphertext: ByteArray): ByteArray {
        val plaintext = cipher.decryptWithAd(h, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    fun clone(): SymmetricState {
        val copy = SymmetricState()
        copy.ck = ck.copyOf()
        copy.h = h.copyOf()
        copy.cipher = cipher.clone()
        return copy
    }

    fun split(): Pair<CipherState, CipherState> {
        val parts = hkdfN(ck, ByteArray(0), 2)
        return CipherState(parts[0]) to CipherState(parts[1])
    }
}

class HandshakeResult(
    val send: CipherState,
    val recv: CipherState,
    val handshakeHash: ByteArray,
    val remoteStatic: ByteArray,
)

private enum class Step { Write1, Read1, Write2, Read2, Done, Split }

class HandshakeState private constructor(
    private val initiator: Boolean,
    staticKey: KeyPair,
    remoteStatic: ByteArray?,
    prologue: ByteArray,
    private val fixedEphemeral: KeyPair?,
) {
    private var sym = SymmetricState()
    private val s = staticKey
    private var e: KeyPair? = null
    private var rs: ByteArray? = remoteStatic
    private var re: ByteArray? = null
    private var step: Step = if (initiator) Step.Write1 else Step.Read1

    init {
        sym.mixHash(prologue)
        if (initiator) {
            val remote = remoteStatic
            if (remote == null || remote.size != DH_BYTES) {
                throw NoiseError("IK needs the responder static key up front", "E_NOISE_KEY")
            }
            rs = remote
            sym.mixHash(remote)
        } else {
            sym.mixHash(s.publicKey)
        }
    }

    val isComplete: Boolean get() = step == Step.Done

    fun writeMessage(payload: ByteArray = ByteArray(0)): ByteArray {
        if (initiator && step == Step.Write1) return writeMessage1(payload)
        if (!initiator && step == Step.Write2) return writeMessage2(payload)
        throw NoiseError("cannot write at step $step", "E_NOISE_STATE")
    }

    fun readMessage(message: ByteArray): ByteArray {
        if (!initiator && step == Step.Read1) return readMessage1(message)
        if (initiator && step == Step.Read2) return readMessage2(message)
        throw NoiseError("cannot read at step $step", "E_NOISE_STATE")
    }

    fun split(): HandshakeResult {
        if (step == Step.Split) throw NoiseError("handshake already split", "E_NOISE_STATE")
        if (step != Step.Done) throw NoiseError("handshake is at step $step", "E_NOISE_STATE")
        val (c1, c2) = sym.split()
        val result = HandshakeResult(
            send = if (initiator) c1 else c2,
            recv = if (initiator) c2 else c1,
            handshakeHash = sym.h,
            remoteStatic = rs!!,
        )
        step = Step.Split
        return result
    }

    private fun writeMessage1(payload: ByteArray): ByteArray {
        e = fixedEphemeral ?: generateKeyPair()
        val eph = e!!
        sym.mixHash(eph.publicKey)
        sym.mixKey(dh(eph.secretKey, rs!!))
        val encStatic = sym.encryptAndHash(s.publicKey)
        sym.mixKey(dh(s.secretKey, rs!!))
        val encPayload = sym.encryptAndHash(payload)
        step = Step.Read2
        return concat(eph.publicKey, encStatic, encPayload)
    }

    private fun readMessage1(message: ByteArray): ByteArray {
        val encStaticEnd = DH_BYTES + DH_BYTES + TAG_BYTES
        if (message.size < encStaticEnd + TAG_BYTES) {
            throw NoiseError("handshake message 1 is ${message.size} bytes", "E_NOISE_MESSAGE")
        }
        val trial = sym.clone()
        val reIn = message.copyOfRange(0, DH_BYTES)
        trial.mixHash(reIn)
        trial.mixKey(dh(s.secretKey, reIn))
        val rsIn = trial.decryptAndHash(message.copyOfRange(DH_BYTES, encStaticEnd))
        trial.mixKey(dh(s.secretKey, rsIn))
        val payload = trial.decryptAndHash(message.copyOfRange(encStaticEnd, message.size))
        sym = trial
        re = reIn
        rs = rsIn
        step = Step.Write2
        return payload
    }

    private fun writeMessage2(payload: ByteArray): ByteArray {
        e = fixedEphemeral ?: generateKeyPair()
        val eph = e!!
        sym.mixHash(eph.publicKey)
        sym.mixKey(dh(eph.secretKey, re!!))
        sym.mixKey(dh(eph.secretKey, rs!!))
        val encPayload = sym.encryptAndHash(payload)
        step = Step.Done
        return concat(eph.publicKey, encPayload)
    }

    private fun readMessage2(message: ByteArray): ByteArray {
        if (message.size < DH_BYTES + TAG_BYTES) {
            throw NoiseError("handshake message 2 is ${message.size} bytes", "E_NOISE_MESSAGE")
        }
        val trial = sym.clone()
        val reIn = message.copyOfRange(0, DH_BYTES)
        trial.mixHash(reIn)
        trial.mixKey(dh(e!!.secretKey, reIn))
        trial.mixKey(dh(s.secretKey, reIn))
        val payload = trial.decryptAndHash(message.copyOfRange(DH_BYTES, message.size))
        sym = trial
        re = reIn
        step = Step.Done
        return payload
    }

    companion object {
        fun initiator(
            staticKey: KeyPair,
            remoteStatic: ByteArray,
            prologue: ByteArray = ByteArray(0),
            ephemeral: KeyPair? = null,
        ): HandshakeState = HandshakeState(true, staticKey, remoteStatic, prologue, ephemeral)

        fun responder(
            staticKey: KeyPair,
            prologue: ByteArray = ByteArray(0),
            ephemeral: KeyPair? = null,
        ): HandshakeState = HandshakeState(false, staticKey, null, prologue, ephemeral)
    }
}
