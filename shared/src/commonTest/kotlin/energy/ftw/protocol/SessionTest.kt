package energy.ftw.protocol

import energy.ftw.carrier.LoopbackCarrier
import energy.ftw.format.FID_GRID_W
import energy.ftw.format.FID_LOAD_W
import energy.ftw.format.FID_PV_W
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SessionTest {
    @Test
    fun helloThenSnapBecomesStreamingWithFrozenFields() {
        val loop = LoopbackCarrier()
        val session = Session(build = "test")
        session.connect(loop)
        loop.markOpen()

        val helloOk = Cbor.map(
            "proto" to Cbor.num(1),
            "mode" to Cbor.txt("full"),
            "box" to Cbor.map("id" to Cbor.txt("box1"), "build" to Cbor.txt("dev"), "tz" to Cbor.txt("UTC")),
            "clock" to Cbor.map("uptimeMs" to Cbor.num(1000), "source" to Cbor.txt("ntp"), "syncedAtMs" to Cbor.num(0)),
            "caps" to Cbor.arr(Cbor.txt("status.core")),
            "modes" to Cbor.arr(Cbor.map("key" to Cbor.txt("self_consumption"))),
            "subscribed" to Cbor.Bool(true),
        )
        loop.peerSend(encodeFrame(Frame(LANE_BULK, 0, Envelope("hello_ok", b = helloOk)), 1024))

        val snap = Cbor.map(
            "uptimeMs" to Cbor.num(3_600_000),
            "controlRev" to Cbor.num(1),
            "fields" to Cbor.map(
                "2" to Cbor.num(1240),
                "3" to Cbor.num(-3400),
                "4" to Cbor.num(-820),
                "5" to Cbor.num(642),
                "6" to Cbor.num(2060),
            ),
            "sources" to Cbor.map(
                "sungrow" to Cbor.map(
                    "kind" to Cbor.txt("driver"),
                    "name" to Cbor.txt("sungrow"),
                    "lastOkMs" to Cbor.num(3_600_000),
                    "staleAfterMs" to Cbor.num(5_000),
                    "state" to Cbor.txt("live"),
                ),
            ),
            "dispatchBlockedBy" to Cbor.arr(),
            "dict" to Cbor.map(),
        )
        loop.peerSend(encodeFrame(Frame(LANE_BULK, 0, Envelope("snap", b = snap)), 4096))

        assertEquals("streaming", session.snapshot.phase)
        assertEquals(1240.0, session.snapshot.readings.fields[FID_GRID_W])
        assertEquals(-3400.0, session.snapshot.readings.fields[FID_PV_W])
        assertEquals(2060.0, session.snapshot.readings.fields[FID_LOAD_W])
        assertTrue(session.snapshot.headline.isNotBlank())
        assertTrue(session.snapshot.heardFromBox)
    }

    @Test
    fun cacheRestorePaintsBeforeConnect() {
        val session = Session()
        session.restore(
            LiveReadings(
                fields = mapOf(FID_GRID_W to 100.0, FID_LOAD_W to 100.0),
            ),
        )
        assertEquals("idle", session.snapshot.phase)
        assertTrue(session.snapshot.headline.isNotBlank())
    }
}
