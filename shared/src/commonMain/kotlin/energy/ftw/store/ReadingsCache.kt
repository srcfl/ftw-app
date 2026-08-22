package energy.ftw.store

import energy.ftw.identity.KeyValueStore
import energy.ftw.protocol.Cbor
import energy.ftw.protocol.LiveReadings
import energy.ftw.protocol.applySnap
import energy.ftw.protocol.decodeCbor
import energy.ftw.protocol.encodeCbor

/**
 * Last live snapshot on this phone. Cold start paints from here, then
 * the session catches up. Not the original — the box is.
 */
class ReadingsCache(private val kv: KeyValueStore) {
    fun get(): LiveReadings? {
        val raw = kv.get(K_READINGS) ?: return null
        val map = decodeCbor(raw) as? Cbor.Map ?: return null
        return applySnap(map)
    }

    fun put(readings: LiveReadings) {
        kv.put(K_READINGS, encodeLiveReadings(readings))
    }

    fun clear() {
        kv.remove(K_READINGS)
    }

    companion object {
        private const val K_READINGS = "readings"
    }
}

internal fun encodeLiveReadings(readings: LiveReadings): ByteArray = encodeCbor(
    Cbor.map(
        "uptimeMs" to Cbor.num(readings.uptimeMs),
        "fields" to Cbor.Map(
            readings.fields.map { (id, value) -> id.toString() to Cbor.txt(value.toString()) },
        ),
        "sources" to Cbor.Map(
            readings.sources.map { (id, source) ->
                id to Cbor.map(
                    "kind" to Cbor.txt(source.kind),
                    "name" to Cbor.txt(source.name),
                    "lastOkMs" to Cbor.num(source.lastOkMs),
                    "staleAfterMs" to Cbor.num(source.staleAfterMs),
                    "state" to Cbor.txt(source.state.name.lowercase()),
                )
            },
        ),
        "dispatchBlockedBy" to Cbor.Arr(readings.dispatchBlockedBy.map { Cbor.txt(it) }),
        "dict" to Cbor.Map(
            readings.dict.map { (id, name) ->
                id.toString() to Cbor.map("name" to Cbor.txt(name))
            },
        ),
    ),
)
