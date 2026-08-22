package energy.ftw.identity

import energy.ftw.crypto.ChaChaPoly
import energy.ftw.crypto.KeyPair
import energy.ftw.crypto.generateKeyPair
import energy.ftw.crypto.keyPairFromSecret
import energy.ftw.crypto.randomBytes
import energy.ftw.protocol.Cbor
import energy.ftw.protocol.decodeCbor
import energy.ftw.protocol.encodeCbor

interface KeyValueStore {
    fun get(key: String): ByteArray?
    fun put(key: String, value: ByteArray)
    fun remove(key: String)
}

class MemoryStore : KeyValueStore {
    private val map = linkedMapOf<String, ByteArray>()
    override fun get(key: String) = map[key]?.copyOf()
    override fun put(key: String, value: ByteArray) {
        map[key] = value.copyOf()
    }
    override fun remove(key: String) {
        map.remove(key)
    }
}

class VaultError(message: String, val code: String, val help: String) : Exception(message)

/**
 * Device Noise static, wrapped under a passkey PRF key and a local copy so
 * reading never prompts. PRF still gates enrollment and privileged commands.
 */
class Vault(private val store: KeyValueStore) {
    fun isEnrolled(): Boolean = readRecord() != null

    fun clear() {
        store.remove(K_VAULT)
        store.remove(K_LOCAL_WRAP)
    }

    fun devicePublic(): ByteArray? = readRecord()?.first

    fun silentWrappingKey(): WrappingKey? {
        val raw = store.get(K_LOCAL_WRAP) ?: return null
        if (raw.size != 32) return null
        return WrappingKey(LOCAL_CREDENTIAL_ID, WrappingSource.Local, raw)
    }

    fun ensureLocalCopy(current: WrappingKey) {
        if (silentWrappingKey() != null) return
        val local = WrappingKey(LOCAL_CREDENTIAL_ID, WrappingSource.Local, randomBytes(32))
        wrapUnder(current, local)
        store.put(K_LOCAL_WRAP, local.key)
    }

    fun deviceKey(wrapping: WrappingKey): KeyPair {
        val record = readRecord()
        if (record == null) return create(wrapping)
        val copy = record.second.firstOrNull { it.first == wrapping.credentialId }
            ?: throw VaultError(
                "no copy for this credential",
                "E_VAULT_NO_COPY",
                "This phone has no key for that home. Scan the code on the box.",
            )
        val secret = unseal(wrapKey(wrapping.key), copy.second, copy.third)
        return keyPairFromSecret(secret)
    }

    fun enroll(passkey: PasskeyHost, label: String = "FTW"): Pair<WrappingKey, KeyPair> {
        val wrapping = if (isEnrolled() && silentWrappingKey() != null) {
            silentWrappingKey()!!
        } else {
            passkey.enroll(label)
        }
        val device = deviceKey(wrapping)
        ensureLocalCopy(wrapping)
        return wrapping to device
    }

    private fun create(wrapping: WrappingKey): KeyPair {
        val pair = generateKeyPair()
        val sealed = seal(wrapKey(wrapping.key), pair.secretKey)
        writeRecord(pair.publicKey, listOf(Triple(wrapping.credentialId, sealed.first, sealed.second)))
        return pair
    }

    private fun wrapUnder(current: WrappingKey, next: WrappingKey) {
        val record = readRecord() ?: throw VaultError("empty vault", "E_VAULT_EMPTY", "Scan the code on the box.")
        val copy = record.second.first { it.first == current.credentialId }
        val secret = unseal(wrapKey(current.key), copy.second, copy.third)
        val sealed = seal(wrapKey(next.key), secret)
        val copies = record.second.filter { it.first != next.credentialId } +
            Triple(next.credentialId, sealed.first, sealed.second)
        writeRecord(record.first, copies)
    }

    private fun wrapKey(key: ByteArray): ByteArray {
        if (key.size < energy.ftw.crypto.ChaChaPoly.KEY_BYTES) {
            throw VaultError(
                "wrapping key too short",
                "E_VAULT_WRAP",
                "That passkey did not yield a key. Try Face ID again.",
            )
        }
        return key.copyOf(energy.ftw.crypto.ChaChaPoly.KEY_BYTES)
    }

    private fun seal(key: ByteArray, secret: ByteArray): Pair<ByteArray, ByteArray> {
        val nonce = randomBytes(12)
        val ct = ChaChaPoly.encrypt(key, nonce, ByteArray(0), secret)
        return nonce to ct
    }

    private fun unseal(key: ByteArray, nonce: ByteArray, ct: ByteArray): ByteArray =
        ChaChaPoly.decrypt(key, nonce, ByteArray(0), ct)

    private fun readRecord(): Pair<ByteArray, List<Triple<String, ByteArray, ByteArray>>>? {
        val raw = store.get(K_VAULT) ?: return null
        val map = decodeCbor(raw) as? Cbor.Map ?: return null
        val pub = (map["public"] as? Cbor.Bytes)?.value ?: return null
        val copies = (map["copies"] as? Cbor.Arr)?.items?.mapNotNull { item ->
            val m = item as? Cbor.Map ?: return@mapNotNull null
            val id = m.text("id") ?: return@mapNotNull null
            val iv = (m["iv"] as? Cbor.Bytes)?.value ?: return@mapNotNull null
            val ct = (m["ct"] as? Cbor.Bytes)?.value ?: return@mapNotNull null
            Triple(id, iv, ct)
        } ?: return null
        return pub to copies
    }

    private fun writeRecord(
        publicKey: ByteArray,
        copies: List<Triple<String, ByteArray, ByteArray>>,
    ) {
        store.put(
            K_VAULT,
            encodeCbor(
                Cbor.map(
                    "public" to Cbor.bytes(publicKey),
                    "copies" to Cbor.Arr(
                        copies.map { (id, iv, ct) ->
                            Cbor.map(
                                "id" to Cbor.txt(id),
                                "iv" to Cbor.bytes(iv),
                                "ct" to Cbor.bytes(ct),
                            )
                        },
                    ),
                ),
            ),
        )
    }

    companion object {
        private const val K_VAULT = "device-key"
        private const val K_LOCAL_WRAP = "local-wrap-key"
    }
}
