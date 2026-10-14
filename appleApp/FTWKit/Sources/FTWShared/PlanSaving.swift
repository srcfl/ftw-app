import Foundation

/// What the plan is worth, as the box's planner reckons it: its own cost for
/// the hours it covers against the cost of the same hours with no battery.
/// Said only when the plan ends about where it starts, because a plan that
/// ends emptier has spent stored energy and the plain difference would
/// flatter it. Never against self-consumption, whose baseline drains the
/// battery and so reads cheaper than it is.
public struct PlanSaving: Equatable, Sendable, Codable {
    /// The plan's cost and the no-battery cost, minor units.
    public var costMinor: Double
    public var noBatteryMinor: Double
    /// The battery's level when the plan starts and where it leaves it, 0 to 1.
    public var startLevel: Double
    public var endLevel: Double
    /// Where the plan's hours end.
    public var endMs: Double

    /// How far the end may sit from the start and still compare honestly.
    public static let levelSlack = 0.05

    public init(costMinor: Double, noBatteryMinor: Double, startLevel: Double, endLevel: Double, endMs: Double) {
        self.costMinor = costMinor
        self.noBatteryMinor = noBatteryMinor
        self.startLevel = startLevel
        self.endLevel = endLevel
        self.endMs = endMs
    }

    /// The saving in minor units, or nil when it cannot be said honestly:
    /// the levels at either end differ, a number is missing, or there is no
    /// saving to speak of.
    public var savedMinor: Double? {
        guard [costMinor, noBatteryMinor, startLevel, endLevel].allSatisfy(\.isFinite),
              abs(endLevel - startLevel) <= Self.levelSlack + 1e-9 else { return nil }
        let saved = noBatteryMinor - costMinor
        return saved >= 100 ? saved : nil
    }

    /// "ABOUT 28 KR LESS THAN NO BATTERY · TO THU 24:00", or nil.
    public func text(currency: String, nowMs: Double, zone: TimeZone) -> String? {
        guard let saved = savedMinor else { return nil }
        let amount = "\(Int((saved / 100).rounded())) \(Self.major(currency))"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let until = Clock(calendar: calendar).at(endMs, asEnd: true, from: nowMs).uppercased(with: Words.locale)
        return DialWord.saving.format(amount, until)
    }

    /// The major unit a hundred minor units make.
    static func major(_ currency: String) -> String {
        switch currency.uppercased() {
        case "SEK", "NOK", "DKK": return "KR"
        case "EUR": return "€"
        case "PLN": return "ZŁ"
        case "CZK": return "KČ"
        case "HUF": return "FT"
        case "RON": return "LEI"
        default: return currency.uppercased()
        }
    }
}
