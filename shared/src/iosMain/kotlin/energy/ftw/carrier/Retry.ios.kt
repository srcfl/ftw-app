package energy.ftw.carrier

import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.dispatch_after
import platform.darwin.dispatch_get_main_queue
import platform.darwin.dispatch_time

internal actual fun scheduleRetry(delayMs: Long, block: () -> Unit) {
    val ns = delayMs * 1_000_000L
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), dispatch_get_main_queue(), block)
}
