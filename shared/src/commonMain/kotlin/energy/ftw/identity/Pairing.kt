package energy.ftw.identity

import energy.ftw.crypto.Sha256
import energy.ftw.toHex

data class PairedSite(
    val siteId: String,
    val label: String,
    val boxStaticKey: ByteArray,
    val pairingCode: ByteArray,
    val rendezvousSecret: ByteArray,
    val lanHint: String?,
)

fun siteIdFor(boxStaticKey: ByteArray): String =
    Sha256.hash(boxStaticKey).copyOf(8).toHex()

fun pairFromScan(scanned: String): Enrollment = parseEnrollmentUrl(scanned)

fun pairedSiteFrom(enrollment: Enrollment, label: String = "Home"): PairedSite =
    PairedSite(
        siteId = siteIdFor(enrollment.boxStaticPublic),
        label = label,
        boxStaticKey = enrollment.boxStaticPublic,
        pairingCode = enrollment.pairingCode,
        rendezvousSecret = enrollment.rendezvousSecret,
        lanHint = enrollment.lanHint.ifEmpty { null },
    )

fun prologueFor(boxStaticKey: ByteArray): ByteArray {
    val tag = "ftw.session.v1:".encodeToByteArray()
    return tag + boxStaticKey
}

private operator fun ByteArray.plus(other: ByteArray): ByteArray {
    val out = ByteArray(size + other.size)
    copyInto(out)
    other.copyInto(out, size)
    return out
}
