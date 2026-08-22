package energy.ftw.format

const val FID_MODE = 1
const val FID_GRID_W = 2
const val FID_PV_W = 3
const val FID_BATTERY_W = 4
const val FID_BATTERY_SOC = 5
const val FID_LOAD_W = 6
const val FID_EV_W = 10

enum class Situation {
    NoData,
    ExportingSurplus,
    ChargingFromSurplus,
    BatteryCovering,
    BatteryShaving,
    SolarCovering,
    SolarPartial,
    Importing,
    DispatchBlocked,
}

data class Explanation(val situation: Situation, val headline: String)

fun explain(
    fields: Map<Int, Double>,
    dispatchBlockedBy: List<String>,
    ceilingW: Double? = null,
): Explanation {
    val grid = fields[FID_GRID_W]
    val pv = fields[FID_PV_W]
    val battery = fields[FID_BATTERY_W]
    val load = fields[FID_LOAD_W]
    if (grid == null || load == null) {
        return Explanation(Situation.NoData, "Waiting for the first reading.")
    }
    if (dispatchBlockedBy.isNotEmpty()) {
        return Explanation(
            Situation.DispatchBlocked,
            "Control is paused because a meter stopped reporting. Your home is running normally on grid power.",
        )
    }
    val generating = if (pv == null) 0.0 else kotlin.math.max(0.0, -pv)
    val bat = battery ?: 0.0
    val ev = fields[FID_EV_W] ?: 0.0
    val carCharging = ev > NOISE_W
    val covered = if (carCharging) "the house and the car" else "the house"

    if (grid < -NOISE_W) {
        return Explanation(
            Situation.ExportingSurplus,
            "Solar is covering the house and sending ${formatPowerKw(grid)} back to the grid.",
        )
    }
    if (bat > NOISE_W && generating > NOISE_W && grid < NOISE_W) {
        return Explanation(
            Situation.ChargingFromSurplus,
            "Spare solar is charging the battery at ${formatPowerKw(bat)}.",
        )
    }
    if (bat < -NOISE_W) {
        if (ceilingW != null && grid > NOISE_W) {
            return Explanation(
                Situation.BatteryShaving,
                "The battery is supplying ${formatPowerKw(bat)} to keep grid import below ${formatPowerKw(ceilingW)}.",
            )
        }
        if (grid < NOISE_W) {
            return Explanation(
                Situation.BatteryCovering,
                "The battery is covering $covered, so nothing is coming from the grid.",
            )
        }
        val headline = if (carCharging) {
            "The car is charging at ${formatPowerKw(ev)}, with the battery supplying ${formatPowerKw(bat)}."
        } else {
            "The battery is supplying ${formatPowerKw(bat)}, with ${formatPowerKw(grid)} from the grid."
        }
        return Explanation(Situation.BatteryShaving, headline)
    }
    if (generating > NOISE_W) {
        if (grid < NOISE_W) {
            return Explanation(Situation.SolarCovering, "Solar is covering everything the house is using.")
        }
        return Explanation(
            Situation.SolarPartial,
            "Solar is covering ${formatPowerKw(generating)} of the ${formatPowerKw(load)} the house is using.",
        )
    }
    if (grid > NOISE_W) {
        return Explanation(Situation.Importing, "The house is drawing ${formatPowerKw(grid)} from the grid.")
    }
    return Explanation(Situation.Importing, "The house is drawing almost nothing right now.")
}
