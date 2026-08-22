package energy.ftw.carrier

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFails
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class RendezvousTest {
    private val secret = ByteArray(32) { 1 }

    @Test
    fun handleIsFixedWidthHex() {
        val handle = rendezvousHandle(secret, 42)
        assertEquals(HANDLE_CHARS, handle.length)
        assertTrue(handle.all { it in '0'..'9' || it in 'a'..'f' })
    }

    @Test
    fun bothEndsAgree() {
        assertEquals(rendezvousHandle(secret, 42), rendezvousHandle(secret, 42))
    }

    @Test
    fun epochsShareNothing() {
        val a = rendezvousHandle(secret, 42)
        val b = rendezvousHandle(secret, 43)
        assertNotEquals(a, b)
        var shared = 0
        for (i in a.indices) if (a[i] == b[i]) shared++
        assertTrue(shared < HANDLE_CHARS / 2)
    }

    @Test
    fun householdsSeparate() {
        val other = ByteArray(32) { 2 }
        assertNotEquals(rendezvousHandle(secret, 42), rendezvousHandle(other, 42))
    }

    @Test
    fun refusesShortSecret() {
        assertFails { rendezvousHandle(ByteArray(8), 42) }
    }

    @Test
    fun epochStepsOncePerHour() {
        assertEquals(0, currentEpoch(0))
        assertEquals(0, currentEpoch(EPOCH_MS - 1))
        assertEquals(1, currentEpoch(EPOCH_MS))
    }
}
