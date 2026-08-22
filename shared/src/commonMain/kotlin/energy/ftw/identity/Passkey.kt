package energy.ftw.identity

import energy.ftw.RP_ID
import energy.ftw.RP_NAME

/** The PRF salt. Changing it strands every vault already wrapped. */
const val PRF_SALT_VAULT = "ftw.prf.v1.vault"

enum class WrappingSource { Prf, Local }

data class WrappingKey(
    val credentialId: String,
    val source: WrappingSource,
    val key: ByteArray,
) {
    override fun equals(other: Any?): Boolean {
        if (other !is WrappingKey) return false
        return credentialId == other.credentialId &&
            source == other.source &&
            key.contentEquals(other.key)
    }

    override fun hashCode() = credentialId.hashCode() * 31 + key.contentHashCode()
}

/**
 * Platform passkey ceremony. Common code never talks to AuthenticationServices
 * or Credential Manager; each UI injects this.
 *
 * The challenge is local random bytes. The box is not a WebAuthn RP.
 * RP ID is [RP_ID] (`app.ftw.energy`).
 */
interface PasskeyHost {
    val rpId: String get() = RP_ID
    val rpName: String get() = RP_NAME
    val prfSalt: ByteArray get() = PRF_SALT_VAULT.encodeToByteArray()

    /** One prompt. Returns PRF output as a wrapping key, or local fallback. */
    fun enroll(label: String = "FTW"): WrappingKey

    fun unlock(label: String = "FTW"): WrappingKey
}

const val LOCAL_CREDENTIAL_ID = "local"

/** Test and JVM e2e: a wrapping key with no authenticator. */
class LocalPasskey(
    private val key: ByteArray = energy.ftw.crypto.randomBytes(32),
) : PasskeyHost {
    override fun enroll(label: String): WrappingKey =
        WrappingKey(LOCAL_CREDENTIAL_ID, WrappingSource.Local, key.copyOf())

    override fun unlock(label: String): WrappingKey = enroll(label)
}
