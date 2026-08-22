package energy.ftw.crypto

expect fun fillRandom(bytes: ByteArray)

fun randomBytes(n: Int): ByteArray {
    val out = ByteArray(n)
    fillRandom(out)
    return out
}
