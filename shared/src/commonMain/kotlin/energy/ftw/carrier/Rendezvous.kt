package energy.ftw.carrier

import energy.ftw.crypto.Hkdf
import energy.ftw.toHex

const val EPOCH_MS = 3_600_000L
const val HANDLE_BYTES = 16
const val HANDLE_CHARS = HANDLE_BYTES * 2

fun currentEpoch(nowMs: Long = nowMs()): Long = nowMs / EPOCH_MS

fun rendezvousHandle(secret: ByteArray, epoch: Long): String {
    if (secret.size < 16) throw IllegalArgumentException("rendezvous secret is too short to be a secret")
    val info = "ftw/rendezvous/v1/$epoch".encodeToByteArray()
    return Hkdf.extractExpand(ByteArray(0), secret, info, HANDLE_BYTES).toHex()
}

expect fun nowMs(): Long
