package energy.ftw.store

import energy.ftw.identity.KeyValueStore
import energy.ftw.identity.MemoryStore
import energy.ftw.identity.PairedSite
import energy.ftw.protocol.Cbor
import energy.ftw.protocol.decodeCbor
import energy.ftw.protocol.encodeCbor

class SiteStore(private val kv: KeyValueStore = MemoryStore()) {
    fun get(id: String): PairedSite? = all().firstOrNull { it.siteId == id }

    fun put(site: PairedSite) {
        val rest = all().filter { it.siteId != site.siteId }
        write(rest + site)
    }

    fun all(): List<PairedSite> {
        val raw = kv.get(K_SITES) ?: return emptyList()
        val arr = decodeCbor(raw) as? Cbor.Arr ?: return emptyList()
        return arr.items.mapNotNull { item ->
            val m = item as? Cbor.Map ?: return@mapNotNull null
            val box = (m["box"] as? Cbor.Bytes)?.value ?: return@mapNotNull null
            val code = (m["code"] as? Cbor.Bytes)?.value ?: return@mapNotNull null
            val secret = (m["secret"] as? Cbor.Bytes)?.value ?: return@mapNotNull null
            PairedSite(
                siteId = m.text("id") ?: return@mapNotNull null,
                label = m.text("label") ?: "Home",
                boxStaticKey = box,
                pairingCode = code,
                rendezvousSecret = secret,
                lanHint = m.text("lan"),
            )
        }
    }

    fun remove(id: String) {
        write(all().filter { it.siteId != id })
    }

    fun clear() {
        kv.remove(K_SITES)
    }

    private fun write(sites: List<PairedSite>) {
        kv.put(
            K_SITES,
            encodeCbor(
                Cbor.Arr(
                    sites.map { s ->
                        Cbor.map(
                            "id" to Cbor.txt(s.siteId),
                            "label" to Cbor.txt(s.label),
                            "box" to Cbor.bytes(s.boxStaticKey),
                            "code" to Cbor.bytes(s.pairingCode),
                            "secret" to Cbor.bytes(s.rendezvousSecret),
                            "lan" to Cbor.txt(s.lanHint ?: ""),
                        )
                    },
                ),
            ),
        )
    }

    companion object {
        private const val K_SITES = "sites"
    }
}
