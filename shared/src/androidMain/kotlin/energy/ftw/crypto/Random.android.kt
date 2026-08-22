package energy.ftw.crypto

import java.security.SecureRandom

private val rng = SecureRandom()

actual fun fillRandom(bytes: ByteArray) {
    rng.nextBytes(bytes)
}
