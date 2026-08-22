package energy.ftw.protocol

data class LiveReadings(
    val uptimeMs: Long = 0,
    val fields: Map<Int, Double> = emptyMap(),
    val sources: Map<String, Source> = emptyMap(),
    val dispatchBlockedBy: List<String> = emptyList(),
    val dict: Map<Int, String> = emptyMap(),
)

fun applySnap(body: Cbor.Map): LiveReadings {
    val uptime = body.long("uptimeMs") ?: 0
    val fields = numMap(body.map("fields"))
    val sources = sourceMap(body.map("sources"))
    val blocked = body.list("dispatchBlockedBy")?.items?.mapNotNull { (it as? Cbor.Txt)?.value } ?: emptyList()
    val dict = linkedMapOf<Int, String>()
    body.map("dict")?.entries?.forEach { (k, v) ->
        val id = k.toIntOrNull() ?: return@forEach
        val name = (v as? Cbor.Map)?.text("name") ?: return@forEach
        dict[id] = name
    }
    return LiveReadings(uptime, fields, sources, blocked, dict)
}

fun applyDelta(current: LiveReadings, body: Cbor.Map): LiveReadings {
    val uptime = body.long("uptimeMs") ?: current.uptimeMs
    val fields = current.fields.toMutableMap().apply { putAll(numMap(body.map("fields"))) }
    val sources = current.sources.toMutableMap().apply { putAll(sourceMap(body.map("sources"))) }
    val blocked = body.list("dispatchBlockedBy")?.items?.mapNotNull { (it as? Cbor.Txt)?.value }
        ?: current.dispatchBlockedBy
    return current.copy(uptimeMs = uptime, fields = fields, sources = sources, dispatchBlockedBy = blocked)
}

private fun numMap(map: Cbor.Map?): Map<Int, Double> {
    if (map == null) return emptyMap()
    val out = linkedMapOf<Int, Double>()
    for ((k, v) in map.entries) {
        val id = k.toIntOrNull() ?: continue
        val n = when (v) {
            is Cbor.Num -> v.value.toDouble()
            is Cbor.Txt -> v.value.toDoubleOrNull() ?: continue
            else -> continue
        }
        out[id] = n
    }
    return out
}

private fun sourceMap(map: Cbor.Map?): Map<String, Source> {
    if (map == null) return emptyMap()
    val out = linkedMapOf<String, Source>()
    for ((id, v) in map.entries) {
        val m = v as? Cbor.Map ?: continue
        out[id] = Source(
            id = id,
            kind = m.text("kind") ?: "",
            name = m.text("name") ?: "",
            lastOkMs = m.long("lastOkMs") ?: 0,
            staleAfterMs = m.long("staleAfterMs") ?: 0,
            state = parseSourceState(m.text("state") ?: "never"),
        )
    }
    return out
}
