package energy.ftw.protocol

enum class CarrierKind { Relay, Cache, None }

enum class SourceState { Live, Lagging, Stale, Down, Never }

data class Source(
    val id: String,
    val kind: String,
    val name: String,
    val lastOkMs: Long,
    val staleAfterMs: Long,
    val state: SourceState,
)

/**
 * Worst source state among the sources that feed the Now fields.
 * Unknown source ids are ignored — a box names its own drivers.
 */
fun siteSourceState(sources: Collection<Source>, usedIds: Set<String>): SourceState {
    val used = sources.filter { it.id in usedIds }
    if (used.isEmpty()) return SourceState.Never
    return used.minBy { rank(it.state) }.state
}

private fun rank(s: SourceState): Int = when (s) {
    SourceState.Never -> 0
    SourceState.Down -> 1
    SourceState.Stale -> 2
    SourceState.Lagging -> 3
    SourceState.Live -> 4
}

fun parseSourceState(raw: String): SourceState = when (raw) {
    "live" -> SourceState.Live
    "lagging" -> SourceState.Lagging
    "stale" -> SourceState.Stale
    "down" -> SourceState.Down
    else -> SourceState.Never
}
