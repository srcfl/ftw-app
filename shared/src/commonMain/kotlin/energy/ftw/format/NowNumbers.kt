package energy.ftw.format

/** Labels the Now screen reads. Both UIs must call this — not format ad hoc. */
data class NowNumbers(
    val grid: String,
    val pv: String,
    val battery: String,
    val load: String,
)

fun nowNumbers(fields: Map<Int, Double>): NowNumbers = NowNumbers(
    grid = fields[FID_GRID_W]?.let { formatPowerKw(it) } ?: "—",
    pv = fields[FID_PV_W]?.let { formatPowerKw(it) } ?: "—",
    battery = fields[FID_BATTERY_W]?.let { formatPowerKw(it) } ?: "—",
    load = fields[FID_LOAD_W]?.let { formatPowerKw(it) } ?: "—",
)
