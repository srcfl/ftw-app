package energy.ftw.carrier

import platform.Foundation.NSDate
import platform.Foundation.timeIntervalSince1970

actual fun nowMs(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()
