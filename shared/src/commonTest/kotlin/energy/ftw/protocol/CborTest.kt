package energy.ftw.protocol

import energy.ftw.toHex
import energy.ftw.hexToBytes
import kotlin.test.Test
import kotlin.test.assertEquals

class CborTest {
    @Test
    fun encodesTheAppsOwnHello() {
        val hello = Cbor.map(
            "t" to Cbor.txt("hello"),
            "b" to Cbor.map(
                "proto" to Cbor.map("min" to Cbor.num(0), "max" to Cbor.num(1)),
                "app" to Cbor.map("build" to Cbor.txt("test"), "ua" to Cbor.txt("pwa")),
                "locales" to Cbor.arr(Cbor.txt("sv")),
            ),
        )
        assertEquals(
            "a261746568656c6c6f6162a36570726f746fa2636d696e00636d61780163617070a2656275696c64647465737462756163707761676c6f63616c657381627376",
            encodeCbor(hello).toHex(),
        )
    }

    @Test
    fun encodesHelloWithSubscription() {
        val hello = helloEnvelope("test", "pwa", listOf("sv"), 512, 1)
        assertEquals(
            "a261746568656c6c6f6162a46570726f746fa2636d696e00636d61780163617070a2656275696c64647465737462756163707761676c6f63616c65738162737663737562a2666275636b657419020062687a01",
            encodeCbor(hello).toHex(),
        )
    }

    @Test
    fun encodesSub() {
        assertEquals(
            "a26174637375626162a2666275636b657419020062687a01",
            encodeCbor(subEnvelope(512, 1)).toHex(),
        )
    }

    @Test
    fun roundTripHello() {
        val raw = "a261746568656c6c6f6162a36570726f746fa2636d696e00636d61780163617070a2656275696c64647465737462756163707761676c6f63616c657381627376".hexToBytes()
        val decoded = decodeCbor(raw) as Cbor.Map
        assertEquals("hello", decoded.text("t"))
        assertEquals("pwa", decoded.map("b")?.map("app")?.text("ua"))
    }

    @Test
    fun controlFrameIsAlwaysTheBucket() {
        val env = Envelope("tick", b = Cbor.map())
        val frame = encodeFrame(Frame(LANE_CONTROL, 0, env), CONTROL_BUCKET)
        assertEquals(CONTROL_BUCKET, frame.size)
        assertEquals("tick", decodeFrame(frame).envelope.t)
    }
}
