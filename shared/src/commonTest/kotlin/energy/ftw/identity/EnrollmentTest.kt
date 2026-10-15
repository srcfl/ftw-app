package energy.ftw.identity

import energy.ftw.APP_HOST
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class EnrollmentTest {
    private val boxKey = ByteArray(32) { 7 }
    private val pairingCode = ByteArray(16) { 9 }
    private val rendezvousSecret = ByteArray(32) { 11 }
    private val payload = Enrollment(boxKey, pairingCode, "192.168.1.42:8443", rendezvousSecret)

    private fun fragment(
        version: String = "v2",
        key: String = encodeBase64url(boxKey),
        code: String = encodeBase64url(pairingCode),
        hint: String = encodeBase64url("192.168.1.42:8443".encodeToByteArray()),
        secret: String = encodeBase64url(rendezvousSecret),
    ) = listOf(version, key, code, hint, secret).joinToString(".")

    private fun codeOf(fn: () -> Unit): EnrollmentErrorCode {
        val err = assertFailsWith<EnrollmentError>(block = fn)
        return err.code
    }

    @Test
    fun secretsSitAfterTheHash() {
        val url = buildEnrollmentUrl(payload)
        assertTrue('?' !in url.substringBefore('#'))
        assertTrue("/p#" in url)
        assertTrue(encodeBase64url(pairingCode) in url.substringAfter('#'))
        assertTrue(encodeBase64url(rendezvousSecret) in url.substringAfter('#'))
        val before = url.substringBefore('#')
        assertTrue(encodeBase64url(pairingCode) !in before)
        assertTrue(encodeBase64url(rendezvousSecret) !in before)
    }

    @Test
    fun roundTripsThroughTheQrText() {
        val parsed = parseEnrollmentUrl(buildEnrollmentUrl(payload))
        assertEquals(payload, parsed)
    }

    @Test
    fun readsFragmentWithOrWithoutHash() {
        assertEquals("192.168.1.42:8443", parseEnrollmentFragment("#${fragment()}").lanHint)
        assertEquals("192.168.1.42:8443", parseEnrollmentFragment(fragment()).lanHint)
    }

    @Test
    fun acceptsEmptyLanHint() {
        val parsed = parseEnrollmentFragment(fragment(hint = ""))
        assertEquals("", parsed.lanHint)
    }

    @Test
    fun acceptsDevOrigin() {
        val url = buildEnrollmentUrl(payload, "http://localhost:5173")
        assertEquals(pairingCode.toList(), parseEnrollmentUrl(url).pairingCode.toList())
    }

    @Test
    fun rejectsAnotherHost() {
        assertEquals(
            EnrollmentErrorCode.E_QR_NOT_FTW,
            codeOf { parseEnrollmentUrl("https://evil.example/p#${fragment()}") },
        )
    }

    @Test
    fun rejectsPlainHttpOnRealHost() {
        assertEquals(
            EnrollmentErrorCode.E_QR_NOT_FTW,
            codeOf { parseEnrollmentUrl("http://$APP_HOST/p#${fragment()}") },
        )
    }

    @Test
    fun rejectsWifiQr() {
        assertEquals(
            EnrollmentErrorCode.E_QR_NOT_FTW,
            codeOf { parseEnrollmentUrl("WIFI:S=Home;T=WPA;P=hunter2;;") },
        )
    }

    @Test
    fun versionDecidesWhoUpdates() {
        val v4 = assertFailsWith<EnrollmentError> { parseEnrollmentFragment(fragment("v4")) }
        assertEquals(EnrollmentErrorCode.E_QR_VERSION, v4.code)
        assertTrue(v4.help.contains("update the app", ignoreCase = true))
        val v1 = assertFailsWith<EnrollmentError> { parseEnrollmentFragment(fragment("v1")) }
        assertTrue(v1.help.contains("update the box", ignoreCase = true))
        assertEquals(EnrollmentErrorCode.E_QR_NOT_FTW, codeOf { parseEnrollmentFragment(fragment("x1")) })
    }

    /** The same v3 code the iPhone's and the web app's tests read. */
    private val v3 =
        "https://app.ftw.energy/p#v3.AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE.AgICAgICAgICAgICAgICAg." +
            "MTAuMC4wLjI6ODA4MA.AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM.Zmp6eXI2N2J1enB5bmNxbWpsaXdnZXp2ZGU"

    @Test
    fun readsAV3CodeAndTheHomeItNames() {
        val parsed = parseEnrollmentUrl(v3)
        assertEquals(
            Enrollment(ByteArray(32) { 1 }, ByteArray(16) { 2 }, "10.0.0.2:8080", ByteArray(32) { 3 }, "fjzyr67buzpyncqmjliwgezvde"),
            parsed,
        )
        assertEquals(v3, buildEnrollmentUrl(parsed))
        assertEquals(null, parseEnrollmentUrl(buildEnrollmentUrl(payload)).home)
        assertTrue("#v2." in buildEnrollmentUrl(payload))
    }

    @Test
    fun aV3CodeMustNameAHome() {
        val segments = v3.substringAfter('#').split('.')
        val noHome = segments.dropLast(1).joinToString(".")
        assertEquals(EnrollmentErrorCode.E_QR_SHAPE, codeOf { parseEnrollmentFragment(noHome) })
        assertEquals(EnrollmentErrorCode.E_QR_SHAPE, codeOf { parseEnrollmentFragment("$noHome.${segments.last()}.AA") })
        assertEquals(EnrollmentErrorCode.E_QR_SHAPE, codeOf { parseEnrollmentFragment(fragment() + "." + segments.last()) })
        val notAHome = encodeBase64url("NOT-A-HOME-AT-ALL-12345678".encodeToByteArray())
        assertEquals(EnrollmentErrorCode.E_QR_HOME, codeOf { parseEnrollmentFragment("$noHome.$notAHome") })
        val short = encodeBase64url("fjzyr67buzpyncqmjliwgezvd".encodeToByteArray())
        assertEquals(EnrollmentErrorCode.E_QR_HOME, codeOf { parseEnrollmentFragment("$noHome.$short") })
        assertEquals(EnrollmentErrorCode.E_QR_ENCODING, codeOf { parseEnrollmentFragment("$noHome.!!") })
    }

    @Test
    fun rejectsShortSecret() {
        val short = encodeBase64url(ByteArray(16) { 11 })
        assertEquals(
            EnrollmentErrorCode.E_QR_SECRET,
            codeOf { parseEnrollmentFragment(fragment(secret = short)) },
        )
    }

    @Test
    fun rejectsBadShape() {
        assertEquals(EnrollmentErrorCode.E_QR_SHAPE, codeOf { parseEnrollmentFragment("v2." + encodeBase64url(boxKey)) })
        assertEquals(EnrollmentErrorCode.E_QR_SHAPE, codeOf { parseEnrollmentFragment(fragment() + ".extra") })
    }

    @Test
    fun rejectsPaddedBase64() {
        assertEquals(
            EnrollmentErrorCode.E_QR_ENCODING,
            codeOf { parseEnrollmentFragment(fragment(key = encodeBase64url(boxKey) + "=")) },
        )
    }

    @Test
    fun rejectsWrongKeyLength() {
        assertEquals(
            EnrollmentErrorCode.E_QR_KEY,
            codeOf { parseEnrollmentFragment(fragment(key = encodeBase64url(ByteArray(31) { 7 }))) },
        )
    }

    @Test
    fun helpNeverLeaksInternals() {
        val help = assertFailsWith<EnrollmentError> {
            parseEnrollmentFragment(fragment(key = "A"))
        }.help
        assertTrue(help.contains("scan it again", ignoreCase = true))
        assertTrue(!help.contains("base64", ignoreCase = true))
        assertTrue(!help.contains("byte", ignoreCase = true))
    }
}
