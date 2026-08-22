package energy.ftw.format

const val NOISE_W = 50

enum class Direction { In, Out, Idle }

data class PowerParts(
    val value: Double,
    val unit: String,
    val direction: Direction,
    val text: String,
)

fun directionOf(watts: Double): Direction {
    if (!watts.isFinite() || kotlin.math.abs(watts) < NOISE_W) return Direction.Idle
    return if (watts > 0) Direction.In else Direction.Out
}

fun formatPower(watts: Double): PowerParts {
    val direction = directionOf(watts)
    val abs = if (watts.isFinite()) kotlin.math.abs(watts) else 0.0
    if (abs < 1000) {
        val rounded = kotlin.math.round(abs).toInt()
        return PowerParts(rounded.toDouble(), "W", direction, rounded.toString())
    }
    if (abs < 1_000_000) {
        val kw = abs / 1000.0
        val text = if (kw < 10) oneDecimal(kw) else kotlin.math.round(kw).toInt().toString()
        return PowerParts(kw, "kW", direction, text)
    }
    val mw = abs / 1_000_000.0
    val text = if (mw < 10) twoDecimals(mw) else oneDecimal(mw)
    return PowerParts(mw, "MW", direction, text)
}

fun formatPowerKw(watts: Double): String {
    val p = formatPower(kotlin.math.abs(watts))
    return "${p.text} ${p.unit}"
}

private fun oneDecimal(n: Double): String {
    val t = kotlin.math.round(n * 10) / 10.0
    val i = t.toInt()
    return if (t == i.toDouble()) "$i.0" else t.toString()
}

private fun twoDecimals(n: Double): String {
    val t = kotlin.math.round(n * 100) / 100.0
    return t.toString()
}
