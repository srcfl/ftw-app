import Foundation

/// Why, not just what.
///
/// "Battery: -4.2 kW" is a number. "The battery is covering the house, so
/// nothing is coming from the grid" is an answer, and a glance has room for
/// one sentence. Where the readings cannot tell, this says less rather than
/// guessing: a confident wrong sentence is worse than a plain one.
public enum Explanation {
    public enum Situation: String, Sendable {
        case noData, exportingSurplus, chargingFromSurplus, batteryCovering, batteryShaving
        case solarCovering, solarPartial, importing, dispatchBlocked
    }

    public struct Result: Equatable, Sendable {
        public let situation: Situation
        public let headline: String
    }

    static func kw(_ watts: Double) -> String { PowerFormat.text(abs(watts)) }

    public static func explain(fields: [Int: Double], dispatchBlockedBy: [String], ceilingW: Double?) -> Result {
        let noise = PowerFormat.noiseW
        guard let grid = fields[Contract.FID.gridW], let load = fields[Contract.FID.loadW] else {
            return Result(situation: .noData, headline: "Waiting for the first reading.")
        }
        // The box's own safety rule outranks everything else it might do.
        if !dispatchBlockedBy.isEmpty {
            return Result(situation: .dispatchBlocked, headline: "Control is paused because a meter stopped reporting. Your home is running normally on grid power.")
        }
        // PV is never positive: -3000 means making 3 kW.
        let generating = max(0, -(fields[Contract.FID.pvW] ?? 0))
        let bat = fields[Contract.FID.batteryW] ?? 0
        let ev = fields[Contract.FID.evW] ?? 0
        let carCharging = ev > noise
        let covered = carCharging ? "the house and the car" : "the house"

        if grid < -noise {
            return Result(situation: .exportingSurplus, headline: "Solar is covering the house and sending \(kw(grid)) back to the grid.")
        }
        if bat > noise, generating > noise, grid < noise {
            return Result(situation: .chargingFromSurplus, headline: "Spare solar is charging the battery at \(kw(bat)).")
        }
        if bat < -noise {
            if let ceilingW, grid > noise {
                return Result(situation: .batteryShaving, headline: "The battery is supplying \(kw(bat)) to keep grid import below \(kw(ceilingW)).")
            }
            if grid < noise {
                return Result(situation: .batteryCovering, headline: "The battery is covering \(covered), so nothing is coming from the grid.")
            }
            return Result(situation: .batteryShaving, headline: carCharging
                ? "The car is charging at \(kw(ev)), with the battery supplying \(kw(bat))."
                : "The battery is supplying \(kw(bat)), with \(kw(grid)) from the grid.")
        }
        if generating > noise {
            if grid < noise {
                return Result(situation: .solarCovering, headline: "Solar is covering everything the house is using.")
            }
            return Result(situation: .solarPartial, headline: "Solar is covering \(kw(generating)) of the \(kw(load)) the house is using.")
        }
        if grid > noise {
            return Result(situation: .importing, headline: "The house is drawing \(kw(grid)) from the grid.")
        }
        return Result(situation: .importing, headline: "The house is drawing almost nothing right now.")
    }
}
