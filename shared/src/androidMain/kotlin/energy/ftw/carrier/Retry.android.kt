package energy.ftw.carrier

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
    Thread(r, "ftw-retry").apply { isDaemon = true }
}

internal actual fun scheduleRetry(delayMs: Long, block: () -> Unit) {
    scheduler.schedule(block, delayMs, TimeUnit.MILLISECONDS)
}
