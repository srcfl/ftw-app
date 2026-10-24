import Foundation
import FTWShared

/// The four places of a home, in the tab bar's order: what flows now, the
/// plan ahead, what the home did, and the home itself with its cars,
/// assistants and this phone (Ring / Quiet, 24 October 2026).
public enum HomeTab: String, CaseIterable, Hashable, Sendable {
    case now, plan, history, home

    /// The tab's name. "Home" is the node's name too, and Swedish says the
    /// two differently ("Hemmet" on Now, "Hem" here), so the tabs keep
    /// their own words.
    public var title: String {
        let sv = AppWords.language == .sv
        switch self {
        case .now: return sv ? "Nu" : "Now"
        case .plan: return sv ? "Plan" : "Plan"
        case .history: return sv ? "Historik" : "History"
        case .home: return sv ? "Hem" : "Home"
        }
    }

    /// The tab bar fills the chosen one's symbol itself.
    public var symbol: String {
        switch self {
        case .now: return "bolt"
        case .plan: return "calendar"
        case .history: return "chart.bar"
        case .home: return "house"
        }
    }
}

/// A row of History: what one node did today, in its own words, from the
/// same tiles the node's chart draws.
public enum DayWords {
    /// "Made 12.4 kWh", "Charged 5.0 kWh · gave 4.2 kWh".
    public static func line(_ node: EnergyNode, _ e: EnergyToday) -> String {
        let a = AppWords.energy(e.inWh), b = AppWords.energy(e.outWh)
        switch node {
        case .solar: return NodeWords.format("Made %@", a)
        case .battery: return NodeWords.format("Charged %@ · gave %@", a, b)
        case .home: return NodeWords.format("Used %@", a)
        case .grid: return NodeWords.format("Bought %@ · sold %@", a, b)
        case .car: return NodeWords.format("Charged %@", a)
        }
    }

    /// The row's words at zero: the shape a row holds, redacted, until the
    /// box has said.
    public static func shape(_ node: EnergyNode) -> String {
        line(node, EnergyToday(inWh: 0, outWh: 0, missingMs: 0))
    }

    /// The car from the box's energy ledger, which counts it apart.
    public static func car(wh: Double) -> String {
        NodeWords.format("Charged %@", AppWords.energy(wh))
    }

    /// "40 min not recorded", once ten minutes or more are missing.
    public static func missing(_ e: EnergyToday) -> String? {
        guard e.missingMs >= 600_000 else { return nil }
        let minutes = Int((e.missingMs / 60_000).rounded())
        return NodeWords.format("%@ not recorded", minutes < 120 ? "\(minutes) min" : "\(minutes / 60) h")
    }
}
