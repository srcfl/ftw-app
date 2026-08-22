package energy.ftw.crypto

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Security.SecRandomCopyBytes
import platform.Security.errSecSuccess
import platform.Security.kSecRandomDefault

@OptIn(ExperimentalForeignApi::class)
actual fun fillRandom(bytes: ByteArray) {
    val rc = bytes.usePinned { pinned ->
        SecRandomCopyBytes(kSecRandomDefault, bytes.size.toULong(), pinned.addressOf(0))
    }
    require(rc == errSecSuccess) { "SecRandomCopyBytes failed: $rc" }
}
