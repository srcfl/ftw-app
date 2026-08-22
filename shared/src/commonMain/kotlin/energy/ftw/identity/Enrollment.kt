package energy.ftw.identity

import energy.ftw.APP_HOST
import energy.ftw.ENROLLMENT_PATH
import energy.ftw.isDevHost

/**
 * The enrollment payload.
 *
 *   https://app.ftw.energy/p#v2.<box_noise_pub>.<pairing_code>.<lan_hint>.<rendezvous_secret>
 *
 * Everything after the `#` is a URL fragment and is never sent in an HTTP
 * request. The trust anchor reaches the app optically.
 */
const val ENROLLMENT_VERSION = "v2"
const val BOX_KEY_BYTES = 32
const val PAIRING_CODE_BYTES = 16
const val RENDEZVOUS_SECRET_BYTES = 32
const val MAX_LAN_HINT_CHARS = 64

data class Enrollment(
    val boxStaticPublic: ByteArray,
    val pairingCode: ByteArray,
    val lanHint: String,
    val rendezvousSecret: ByteArray,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Enrollment) return false
        return boxStaticPublic.contentEquals(other.boxStaticPublic) &&
            pairingCode.contentEquals(other.pairingCode) &&
            lanHint == other.lanHint &&
            rendezvousSecret.contentEquals(other.rendezvousSecret)
    }

    override fun hashCode(): Int {
        var h = boxStaticPublic.contentHashCode()
        h = 31 * h + pairingCode.contentHashCode()
        h = 31 * h + lanHint.hashCode()
        h = 31 * h + rendezvousSecret.contentHashCode()
        return h
    }
}

enum class EnrollmentErrorCode {
    E_QR_NOT_FTW,
    E_QR_VERSION,
    E_QR_SHAPE,
    E_QR_ENCODING,
    E_QR_KEY,
    E_QR_CODE,
    E_QR_HINT,
    E_QR_SECRET,
}

class EnrollmentError(
    message: String,
    val code: EnrollmentErrorCode,
    /** What the user does now. Never what broke inside. */
    val help: String,
) : Exception(message)

private const val SCAN_AGAIN =
    "That code did not read cleanly. Hold the phone steady and scan it again."
private const val WRONG_CODE =
    "That is not an FTW pairing code. Open your box's local dashboard, then Settings → FTW app → Show pairing code, and scan the QR shown there."
private const val APP_TOO_OLD =
    "This box needs a newer version of the app. Update the app, then scan again."
private const val BOX_TOO_OLD =
    "This box needs a software update before it can pair. Update the box, then scan again."

private val OUR_VERSION = ENROLLMENT_VERSION.removePrefix("v").toInt()

fun parseEnrollmentUrl(raw: String): Enrollment {
    val url = try {
        ParsedUrl.parse(raw)
    } catch (_: IllegalArgumentException) {
        throw EnrollmentError("not a URL: ${raw.take(24)}", EnrollmentErrorCode.E_QR_NOT_FTW, WRONG_CODE)
    }

    val httpsOrDev = url.scheme == "https" || (url.scheme == "http" && isDevHost(url.host))
    if (!httpsOrDev) {
        throw EnrollmentError("scheme ${url.scheme} is not https", EnrollmentErrorCode.E_QR_NOT_FTW, WRONG_CODE)
    }
    if (url.host != APP_HOST && !isDevHost(url.host)) {
        throw EnrollmentError("host ${url.host} is not FTW", EnrollmentErrorCode.E_QR_NOT_FTW, WRONG_CODE)
    }
    if (url.path != ENROLLMENT_PATH) {
        throw EnrollmentError(
            "path ${url.path} is not $ENROLLMENT_PATH",
            EnrollmentErrorCode.E_QR_NOT_FTW,
            WRONG_CODE,
        )
    }
    return parseEnrollmentFragment(url.fragment)
}

fun parseEnrollmentFragment(fragment: String): Enrollment {
    val body = if (fragment.startsWith('#')) fragment.substring(1) else fragment
    if (body.isEmpty()) {
        throw EnrollmentError("empty fragment", EnrollmentErrorCode.E_QR_NOT_FTW, WRONG_CODE)
    }

    val parts = body.split('.')
    val version = parts[0]

    if (version != ENROLLMENT_VERSION) {
        if (version.matches(Regex("^v\\d+$"))) {
            val n = version.substring(1).toInt()
            val help = if (n < OUR_VERSION) BOX_TOO_OLD else APP_TOO_OLD
            throw EnrollmentError("payload version $version", EnrollmentErrorCode.E_QR_VERSION, help)
        }
        throw EnrollmentError("fragment does not start with a version", EnrollmentErrorCode.E_QR_NOT_FTW, WRONG_CODE)
    }

    if (parts.size != 5) {
        throw EnrollmentError("${parts.size} segments, expected 5", EnrollmentErrorCode.E_QR_SHAPE, SCAN_AGAIN)
    }

    val boxStaticPublic = decodeSegment(parts[1], "box key")
    val pairingCode = decodeSegment(parts[2], "pairing code")
    val lanHint = decodeSegment(parts[3], "lan hint").decodeToString()
    val rendezvousSecret = decodeSegment(parts[4], "rendezvous secret")

    if (boxStaticPublic.size != BOX_KEY_BYTES) {
        throw EnrollmentError(
            "box key is ${boxStaticPublic.size} bytes, expected $BOX_KEY_BYTES",
            EnrollmentErrorCode.E_QR_KEY,
            SCAN_AGAIN,
        )
    }
    if (pairingCode.size != PAIRING_CODE_BYTES) {
        throw EnrollmentError(
            "pairing code is ${pairingCode.size} bytes, expected $PAIRING_CODE_BYTES",
            EnrollmentErrorCode.E_QR_CODE,
            SCAN_AGAIN,
        )
    }
    if (lanHint.length > MAX_LAN_HINT_CHARS || lanHint.any { it.code < 0x21 || it.code > 0x7e }) {
        throw EnrollmentError("lan hint is not a plain address", EnrollmentErrorCode.E_QR_HINT, SCAN_AGAIN)
    }
    if (rendezvousSecret.size != RENDEZVOUS_SECRET_BYTES) {
        throw EnrollmentError(
            "rendezvous secret is ${rendezvousSecret.size} bytes, expected $RENDEZVOUS_SECRET_BYTES",
            EnrollmentErrorCode.E_QR_SECRET,
            SCAN_AGAIN,
        )
    }

    return Enrollment(boxStaticPublic, pairingCode, lanHint, rendezvousSecret)
}

fun buildEnrollmentUrl(enrollment: Enrollment, origin: String = "https://$APP_HOST"): String {
    val fragment = listOf(
        ENROLLMENT_VERSION,
        encodeBase64url(enrollment.boxStaticPublic),
        encodeBase64url(enrollment.pairingCode),
        encodeBase64url(enrollment.lanHint.encodeToByteArray()),
        encodeBase64url(enrollment.rendezvousSecret),
    ).joinToString(".")
    return "$origin$ENROLLMENT_PATH#$fragment"
}

private fun decodeSegment(segment: String, what: String): ByteArray {
    try {
        return decodeBase64url(segment)
    } catch (err: Base64urlError) {
        throw EnrollmentError("$what: ${err.message}", EnrollmentErrorCode.E_QR_ENCODING, SCAN_AGAIN)
    }
}

/**
 * Tiny URL parser so commonMain does not depend on java.net.URI.
 * Handles https://host[:port]/path#fragment and http://localhost.
 */
internal data class ParsedUrl(
    val scheme: String,
    val host: String,
    val path: String,
    val fragment: String,
) {
    companion object {
        fun parse(raw: String): ParsedUrl {
            val schemeEnd = raw.indexOf("://")
            if (schemeEnd <= 0) throw IllegalArgumentException("no scheme")
            val scheme = raw.substring(0, schemeEnd)
            val rest = raw.substring(schemeEnd + 3)
            val hash = rest.indexOf('#')
            val beforeHash = if (hash >= 0) rest.substring(0, hash) else rest
            val fragment = if (hash >= 0) rest.substring(hash + 1) else ""
            val slash = beforeHash.indexOf('/')
            val hostPort = if (slash >= 0) beforeHash.substring(0, slash) else beforeHash
            val path = if (slash >= 0) beforeHash.substring(slash) else "/"
            if (hostPort.isEmpty()) throw IllegalArgumentException("no host")
            val host = hostPort.substringBefore(':')
            return ParsedUrl(scheme, host, path, fragment)
        }
    }
}
