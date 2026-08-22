package energy.ftw.carrier

import energy.ftw.RELAY_URL
import kotlin.random.Random

const val CLOSE_BAD_JOIN = 4400
const val CLOSE_EPOCH = 4409
const val CLOSE_ROTATED = 4410
const val CLOSE_BUSY = 4429
const val CTRL_READY = "ready"
const val CTRL_GONE = "gone"
const val BACKOFF_BASE_MS = 500L
const val BACKOFF_CAP_MS = 60_000L
const val ROTATE_JITTER_MS = 3_000L
private const val CORRECTION_LIMIT = 2
private const val MAX_EPOCH_CORRECTION = 1

class RelayCarrier(
    private val url: String = RELAY_URL,
    private val secret: ByteArray,
    private val sockets: SocketFactory,
    private val clock: () -> Long = { nowMs() },
    private val random: () -> Double = { Random.nextDouble() },
) : CarrierBase() {
    override val kind = CarrierKind.Relay

    private var socket: RawSocket? = null
    private var shutdown = false
    private var epochOffset = 0L
    private var attempt = 0
    private var corrections = 0
    private var retry: (() -> Unit)? = null

    init {
        dial()
    }

    override fun send(frame: ByteArray) {
        if (status !is CarrierStatus.Open) return
        socket?.sendBinary(frame)
    }

    override fun wake() {
        if (shutdown) return
        drop()
        attempt = 0
        dial()
    }

    override fun close(reason: String) {
        shutdown = true
        drop()
        super.close(reason)
    }

    private fun dial() {
        if (shutdown) return
        val epoch = currentEpoch(clock()) + epochOffset
        val handle = rendezvousHandle(secret, epoch)
        val origin = url.trimEnd('/')
        val target = "$origin/r/$epoch/$handle/app"
        emitStatus(CarrierStatus.Connecting)
        val listener = object : SocketListener {
            override fun onOpen() {}
            override fun onBinary(bytes: ByteArray) {
                if (status is CarrierStatus.Open) {
                    attempt = 0
                    emitFrame(bytes)
                }
            }
            override fun onText(text: String) {
                when (text) {
                    CTRL_READY -> {
                        corrections = 0
                        emitStatus(CarrierStatus.Open(clock()))
                    }
                    CTRL_GONE -> emitStatus(CarrierStatus.Closed("box offline", retryable = true))
                }
            }
            override fun onClose(code: Int, reason: String) {
                if (shutdown) return
                socket = null
                val delay = when (code) {
                    CLOSE_ROTATED -> {
                        adoptEpoch(reason)
                        (random() * ROTATE_JITTER_MS).toLong()
                    }
                    CLOSE_EPOCH -> {
                        adoptEpoch(reason)
                        corrections++
                        if (corrections > CORRECTION_LIMIT) backoff() else 0L
                    }
                    else -> backoff()
                }
                emitStatus(CarrierStatus.Closed(closeReason(code), retryable = true))
                schedule(delay)
            }
        }
        socket = sockets.open(target, listener)
    }

    private fun adoptEpoch(announced: String) {
        val trimmed = announced.trim()
        if (!trimmed.matches(Regex("^-?\\d+$"))) return
        val epoch = trimmed.toLongOrNull() ?: return
        val offset = epoch - currentEpoch(clock())
        if (kotlin.math.abs(offset) > MAX_EPOCH_CORRECTION) return
        epochOffset = offset
    }

    private fun backoff(): Long {
        val ceiling = minOf(BACKOFF_CAP_MS, BACKOFF_BASE_MS * (1L shl minOf(attempt, 16)))
        attempt = minOf(attempt + 1, 16)
        return (random() * ceiling).toLong()
    }

    private fun schedule(delayMs: Long) {
        if (shutdown) return
        // Tests and production inject their own wait by calling dial after
        // delay. A zero delay redials immediately.
        if (delayMs <= 0L) {
            dial()
            return
        }
        scheduleRetry(delayMs) { if (!shutdown) dial() }
    }

    private fun drop() {
        val s = socket
        socket = null
        s?.close()
    }
}

internal expect fun scheduleRetry(delayMs: Long, block: () -> Unit)

private fun closeReason(code: Int): String = when (code) {
    CLOSE_EPOCH, CLOSE_ROTATED -> "rendezvous rotated"
    CLOSE_BUSY -> "relay busy"
    CLOSE_BAD_JOIN -> "bad join"
    else -> "disconnected"
}
