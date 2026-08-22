package energy.ftw.format

import kotlin.test.Test
import kotlin.test.assertEquals

class NowNumbersTest {
    @Test
    fun formatsFrozenFieldsTheNowScreenShows() {
        val n = nowNumbers(
            mapOf(
                FID_GRID_W to 1240.0,
                FID_PV_W to -3400.0,
                FID_BATTERY_W to -820.0,
                FID_LOAD_W to 2060.0,
            ),
        )
        assertEquals(formatPowerKw(1240.0), n.grid)
        assertEquals(formatPowerKw(-3400.0), n.pv)
        assertEquals(formatPowerKw(-820.0), n.battery)
        assertEquals(formatPowerKw(2060.0), n.load)
    }

    @Test
    fun missingFieldsAreEmDashes() {
        val n = nowNumbers(emptyMap())
        assertEquals("—", n.grid)
        assertEquals("—", n.pv)
        assertEquals("—", n.battery)
        assertEquals("—", n.load)
    }
}
