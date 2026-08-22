package energy.ftw.client

import energy.ftw.carrier.SocketFactory
import energy.ftw.identity.Enrollment
import energy.ftw.identity.LocalPasskey
import energy.ftw.identity.MemoryStore
import energy.ftw.identity.PasskeyHost
import energy.ftw.identity.Vault
import energy.ftw.identity.WrappingKey
import energy.ftw.identity.buildEnrollmentUrl
import energy.ftw.store.SiteStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PairWrappingTest {
    @Test
    fun pairWithWrappingDoesNotCallPasskeyHost() {
        var enrolled = 0
        val passkeys = object : PasskeyHost {
            override fun enroll(label: String): WrappingKey {
                enrolled += 1
                error("passkey host must not run when wrapping is supplied")
            }

            override fun unlock(label: String): WrappingKey = enroll(label)
        }
        val wrapping = LocalPasskey().enroll()
        val vault = Vault(MemoryStore())
        val sites = SiteStore(MemoryStore())
        val sockets = SocketFactory { _, _ -> error("no socket") }
        val client = FtwClient(vault, sites, sockets, passkeys)
        val enrollment = Enrollment(
            boxStaticPublic = ByteArray(32) { 7 },
            pairingCode = ByteArray(16) { 9 },
            lanHint = "192.168.1.42:8443",
            rendezvousSecret = ByteArray(32) { 11 },
        )
        val site = client.pair(buildEnrollmentUrl(enrollment), wrapping)
        assertEquals(0, enrolled)
        assertTrue(vault.isEnrolled())
        assertNotNull(vault.silentWrappingKey())
        assertEquals(site.siteId, sites.all().single().siteId)
        assertTrue(enrollment.boxStaticPublic.contentEquals(site.boxStaticKey))
        assertTrue(enrollment.pairingCode.contentEquals(site.pairingCode))
        assertTrue(enrollment.rendezvousSecret.contentEquals(site.rendezvousSecret))
    }
}
