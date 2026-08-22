package energy.ftw.identity

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VaultTest {
    @Test
    fun enrollCreatesDeviceKeyAndSilentLocalCopy() {
        val vault = Vault(MemoryStore())
        val passkey = LocalPasskey()
        val (wrapping, device) = vault.enroll(passkey)
        assertTrue(vault.isEnrolled())
        assertNotNull(vault.devicePublic())
        vault.ensureLocalCopy(wrapping)
        val silent = vault.silentWrappingKey()
        assertNotNull(silent)
        val again = vault.deviceKey(silent)
        assertTrue(device.publicKey.contentEquals(again.publicKey))
        assertTrue(device.secretKey.contentEquals(again.secretKey))
    }

    @Test
    fun readingDoesNotNeedASecondCeremony() {
        val vault = Vault(MemoryStore())
        vault.enroll(LocalPasskey())
        assertNotNull(vault.silentWrappingKey())
        assertEquals(WrappingSource.Local, vault.silentWrappingKey()!!.source)
    }
}
