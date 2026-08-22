package energy.ftw.client

import energy.ftw.carrier.JvmSockets
import energy.ftw.crypto.generateKeyPair
import energy.ftw.format.FID_GRID_W
import energy.ftw.format.FID_LOAD_W
import energy.ftw.identity.pairFromScan
import energy.ftw.identity.pairedSiteFrom
import energy.ftw.protocol.Session
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Drives the shipped connect path against a live FTW box.
 *
 * Set FTW_LIVE_BOX (host:port, e.g. 127.0.0.1:8080) after `make dev`.
 * Relay defaults to the production origin the box itself joins.
 */
class FtwLiveBoxTest {
    @Test
    fun pairsThroughNoiseAndReceivesASnapshot() {
        val box = System.getenv("FTW_LIVE_BOX")
        org.junit.Assume.assumeFalse(
            "set FTW_LIVE_BOX=127.0.0.1:8080 after make dev to run the live path",
            box.isNullOrBlank(),
        )
        val relay = System.getenv("FTW_LIVE_RELAY") ?: "wss://relay.ftw.energy"

        val minted = mintPairing(box)
        val enrollment = pairFromScan(minted)
        val site = pairedSiteFrom(enrollment)
        val device = generateKeyPair()
        val session = connectToSite(site, device, JvmSockets(), relayUrl = relay, build = "e2e")

        val snap = waitFor(session, "streaming snapshot", pick = { s ->
            if (s.snapshot.phase == "streaming" && s.snapshot.readings.fields.containsKey(FID_GRID_W)) s else null
        })
        val grid = snap.snapshot.readings.fields[FID_GRID_W]
        val load = snap.snapshot.readings.fields[FID_LOAD_W]
        assertNotNull(grid)
        assertNotNull(load)
        assertTrue(snap.snapshot.heardFromBox)
        assertTrue(snap.snapshot.headline.isNotBlank())
        println(
            "e2e box=${snap.snapshot.boxId} build=${snap.snapshot.boxBuild} " +
                "phase=${snap.snapshot.phase} grid=$grid load=$load " +
                "headline=${snap.snapshot.headline}",
        )
        session.close()
    }

    private fun mintPairing(box: String): String {
        val client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()
        val req = HttpRequest.newBuilder(URI.create("http://$box/api/app-link/pairing"))
            .timeout(Duration.ofSeconds(10))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString("{\"role\":\"owner\"}"))
            .build()
        val res = client.send(req, HttpResponse.BodyHandlers.ofString())
        if (res.statusCode() !in 200..299) {
            fail("pairing endpoint said ${res.statusCode()}: ${res.body()}")
        }
        val body = res.body()
        val url = Regex("\"url\"\\s*:\\s*\"([^\"]+)\"").find(body)?.groupValues?.get(1)
            ?: fail("pairing JSON had no url: $body")
        return url.replace("\\u0026", "&").replace("\\/", "/")
    }

    private fun <T> waitFor(session: Session, what: String, pick: (Session) -> T?, timeoutMs: Long = 45_000): T {
        val deadline = System.currentTimeMillis() + timeoutMs
        var last = session.snapshot.phase
        while (System.currentTimeMillis() < deadline) {
            pick(session)?.let { return it }
            last = session.snapshot.phase
            Thread.sleep(100)
        }
        fail(
            "timed out waiting for $what; phase=$last headline=${session.snapshot.headline} " +
                "types=${session.snapshot.seenTypes}",
        )
    }
}
