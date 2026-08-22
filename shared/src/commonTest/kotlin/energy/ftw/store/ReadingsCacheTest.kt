package energy.ftw.store

import energy.ftw.format.FID_GRID_W
import energy.ftw.format.FID_LOAD_W
import energy.ftw.identity.MemoryStore
import energy.ftw.protocol.LiveReadings
import energy.ftw.protocol.Source
import energy.ftw.protocol.SourceState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReadingsCacheTest {
    @Test
    fun roundTripsTheFieldsNowPaints() {
        val cache = ReadingsCache(MemoryStore())
        val readings = LiveReadings(
            uptimeMs = 12_000,
            fields = mapOf(FID_GRID_W to 1240.0, FID_LOAD_W to 2060.0),
            sources = mapOf(
                "meter" to Source(
                    id = "meter",
                    kind = "meter",
                    name = "Grid",
                    lastOkMs = 100,
                    staleAfterMs = 5_000,
                    state = SourceState.Live,
                ),
            ),
            dispatchBlockedBy = emptyList(),
            dict = mapOf(FID_GRID_W to "grid_w"),
        )
        cache.put(readings)
        val got = cache.get()
        assertEquals(12_000, got?.uptimeMs)
        assertEquals(1240.0, got?.fields?.get(FID_GRID_W))
        assertEquals(2060.0, got?.fields?.get(FID_LOAD_W))
        assertEquals(SourceState.Live, got?.sources?.get("meter")?.state)
        assertEquals("grid_w", got?.dict?.get(FID_GRID_W))
    }

    @Test
    fun missingCacheIsNullAndClearWipes() {
        val cache = ReadingsCache(MemoryStore())
        assertNull(cache.get())
        cache.put(LiveReadings(fields = mapOf(FID_GRID_W to 1.0)))
        assertTrue(cache.get()?.fields?.containsKey(FID_GRID_W) == true)
        cache.clear()
        assertNull(cache.get())
    }
}
