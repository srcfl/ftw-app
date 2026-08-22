package energy.ftw.protocol

import energy.ftw.carrier.Carrier
import energy.ftw.carrier.CarrierKind
import energy.ftw.carrier.CarrierStatus
import energy.ftw.format.explain

data class SessionSnapshot(
    val phase: String = "idle",
    val carrier: CarrierKind = CarrierKind.None,
    val heardFromBox: Boolean = false,
    val role: String = "owner",
    val boxId: String? = null,
    val boxBuild: String? = null,
    val readings: LiveReadings = LiveReadings(),
    val headline: String = "Waiting for the first reading.",
    val srcState: SourceState = SourceState.Never,
    val seenTypes: List<String> = emptyList(),
)

class Session(private val build: String = "native", private val ua: String = "native") {
    var snapshot: SessionSnapshot = SessionSnapshot()
        private set

    private var carrier: Carrier? = null
    private val unsub = mutableListOf<() -> Unit>()
    private val listeners = linkedSetOf<(SessionSnapshot) -> Unit>()
    private var helloSubSent = false

    fun subscribe(listener: (SessionSnapshot) -> Unit): () -> Unit {
        listeners.add(listener)
        listener(snapshot)
        return { listeners.remove(listener) }
    }

    fun restore(readings: LiveReadings) {
        if (snapshot.phase == "streaming") return
        patch(
            snapshot.copy(
                readings = readings,
                headline = headlineOf(readings),
                srcState = siteSourceState(readings.sources.values, usedSourceIds(readings)),
                carrier = if (snapshot.phase == "idle") CarrierKind.Cache else snapshot.carrier,
            ),
        )
    }

    fun connect(next: Carrier) {
        detach()
        patch(snapshot.copy(phase = "idle", carrier = CarrierKind.None))
        carrier = next
        unsub += next.onFrame { onFrame(it) }
        unsub += next.onStatus { status ->
            when (status) {
                is CarrierStatus.Open -> {
                    patch(snapshot.copy(phase = "handshaking", carrier = next.kind))
                    sendHello()
                }
                is CarrierStatus.Closed -> {
                    patch(snapshot.copy(phase = "failed", carrier = CarrierKind.None))
                }
                CarrierStatus.Connecting -> {}
            }
        }
        if (next.status is CarrierStatus.Open) {
            patch(snapshot.copy(phase = "handshaking", carrier = next.kind))
            sendHello()
        }
    }

    fun close() {
        detach()
        patch(snapshot.copy(phase = "idle", carrier = CarrierKind.None))
    }

    private fun sendHello() {
        helloSubSent = true
        sendControl(helloEnvelope(build, ua, listOf("en"), CONTROL_BUCKET, 1))
    }

    private fun sendSub() {
        sendControl(subEnvelope(CONTROL_BUCKET, 1))
    }

    private fun sendControl(envelope: Cbor) {
        val t = (envelope as Cbor.Map).text("t") ?: return
        val b = envelope["b"]
        val env = Envelope(t, b = b)
        carrier?.send(encodeFrame(Frame(LANE_CONTROL, 0, env), CONTROL_BUCKET))
    }

    private fun onFrame(bytes: ByteArray) {
        val frame = try {
            decodeFrame(bytes)
        } catch (_: FrameError) {
            return
        }
        val t = frame.envelope.t
        patch(snapshot.copy(seenTypes = snapshot.seenTypes + t))
        when (t) {
            "hello_ok" -> onHelloOk(frame.envelope.b as? Cbor.Map ?: nestedMap(frame.envelope.b))
            "snap" -> onSnap(frame.envelope.b as? Cbor.Map ?: nestedMap(frame.envelope.b))
            "delta" -> onDelta(frame.envelope.b as? Cbor.Map ?: nestedMap(frame.envelope.b))
            "tick" -> onTick(frame.envelope.b as? Cbor.Map ?: nestedMap(frame.envelope.b))
        }
    }

    private fun onHelloOk(body: Cbor.Map?) {
        if (body == null) return
        val subscribed = body.bool("subscribed") == true
        val box = body.map("box")
        patch(
            snapshot.copy(
                phase = if (subscribed) "subscribing" else "subscribing",
                heardFromBox = true,
                role = body.text("role") ?: "owner",
                boxId = box?.text("id"),
                boxBuild = box?.text("build"),
            ),
        )
        sendSub()
    }

    private fun onSnap(body: Cbor.Map?) {
        if (body == null) return
        val readings = applySnap(body)
        patch(
            snapshot.copy(
                phase = "streaming",
                carrier = carrier?.kind ?: snapshot.carrier,
                readings = readings,
                headline = headlineOf(readings),
                srcState = siteSourceState(readings.sources.values, usedSourceIds(readings)),
            ),
        )
    }

    private fun onDelta(body: Cbor.Map?) {
        if (body == null) return
        val readings = applyDelta(snapshot.readings, body)
        patch(
            snapshot.copy(
                phase = "streaming",
                readings = readings,
                headline = headlineOf(readings),
                srcState = siteSourceState(readings.sources.values, usedSourceIds(readings)),
            ),
        )
    }

    private fun onTick(body: Cbor.Map?) {
        val uptime = body?.long("uptimeMs") ?: return
        patch(snapshot.copy(readings = snapshot.readings.copy(uptimeMs = uptime)))
    }

    private fun patch(next: SessionSnapshot) {
        snapshot = next
        for (l in listeners.toList()) l(next)
    }

    private fun detach() {
        unsub.forEach { it() }
        unsub.clear()
        carrier?.close()
        carrier = null
    }
}

fun headlineOf(readings: LiveReadings): String =
    explain(readings.fields, readings.dispatchBlockedBy).headline

private fun usedSourceIds(readings: LiveReadings): Set<String> =
    readings.sources.keys

private fun nestedMap(value: Cbor?): Cbor.Map? {
    val bytes = (value as? Cbor.Bytes)?.value ?: return null
    return decodeCbor(bytes) as? Cbor.Map
}
