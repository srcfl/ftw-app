package energy.ftw.client

import energy.ftw.RELAY_URL
import energy.ftw.carrier.Carrier
import energy.ftw.carrier.NoiseCarrier
import energy.ftw.carrier.RelayCarrier
import energy.ftw.carrier.SocketFactory
import energy.ftw.crypto.KeyPair
import energy.ftw.identity.PairedSite
import energy.ftw.identity.PasskeyHost
import energy.ftw.identity.Vault
import energy.ftw.identity.pairFromScan
import energy.ftw.identity.pairedSiteFrom
import energy.ftw.identity.prologueFor
import energy.ftw.protocol.Session
import energy.ftw.store.SiteStore

class ConnectError(val code: String, val help: String) : Exception(help)

/**
 * The one path: parse QR, unlock vault, store the site, open relay + Noise + session.
 */
class FtwClient(
    private val vault: Vault,
    private val sites: SiteStore,
    private val sockets: SocketFactory,
    private val passkeys: PasskeyHost,
    private val relayUrl: String = RELAY_URL,
    private val build: String = "native",
) {
    fun pair(scanned: String): PairedSite {
        val enrollment = pairFromScan(scanned)
        vault.enroll(passkeys)
        val site = pairedSiteFrom(enrollment)
        sites.put(site)
        return site
    }

    fun connect(site: PairedSite = sites.all().firstOrNull() ?: throw ConnectError("not_paired", "This phone has no record of that home.")): Session {
        if (!vault.isEnrolled()) {
            throw ConnectError("not_enrolled", "This device has no key for that home.")
        }
        val wrapping = vault.silentWrappingKey()
            ?: throw ConnectError("locked", "Unlock this phone, then open FTW again.")
        val device = vault.deviceKey(wrapping)
        return openSession(site, device)
    }

    fun openSession(site: PairedSite, device: KeyPair): Session {
        val inner = RelayCarrier(url = relayUrl, secret = site.rendezvousSecret, sockets = sockets)
        val noise = NoiseCarrier(
            inner = inner,
            staticKey = device,
            remoteStatic = site.boxStaticKey,
            prologue = prologueFor(site.boxStaticKey),
            handshakePayload = site.pairingCode,
        )
        val session = Session(build = build)
        session.connect(noise)
        return session
    }

    fun attach(session: Session, carrier: Carrier) {
        session.connect(carrier)
    }
}

fun connectToSite(
    site: PairedSite,
    device: KeyPair,
    sockets: SocketFactory,
    relayUrl: String = RELAY_URL,
    build: String = "native",
): Session {
    return FtwClient(
        vault = energy.ftw.identity.Vault(energy.ftw.identity.MemoryStore()),
        sites = SiteStore(),
        sockets = sockets,
        passkeys = energy.ftw.identity.LocalPasskey(),
        relayUrl = relayUrl,
        build = build,
    ).openSession(site, device)
}
