import Foundation

/// Power in words and figures.
///
/// FTW's convention is right for the wire and wrong for a person: nobody
/// reads "-4200 W" and thinks "the battery is covering the house". So the
/// UI never shows a raw minus sign. It shows a direction word and a
/// magnitude, and each screen supplies its own vocabulary.
public enum PowerFormat {
    public enum Direction: Equatable, Sendable {
        case into, out, idle
    }

    /// Below this a reading is sensor noise. One threshold for the headline
    /// and the cards, or they contradict each other on the same screen.
    public static let noiseW: Double = 50

    public struct Parts: Equatable, Sendable {
        /// Magnitude in `unit`, never negative.
        public let value: Double
        public let unit: String
        public let direction: Direction
        /// Ready to show: "4.2", with decimals that keep digits from jumping.
        public let text: String

        public var joined: String { "\(text) \(unit)" }
    }

    public static func direction(_ watts: Double) -> Direction {
        guard watts.isFinite, abs(watts) >= noiseW else { return .idle }
        return watts > 0 ? .into : .out
    }

    public static func parts(_ watts: Double) -> Parts {
        let dir = direction(watts)
        let a = watts.isFinite ? abs(watts) : 0
        if a < 1000 {
            let w = a.rounded()
            return Parts(value: w, unit: "W", direction: dir, text: String(Int(w)))
        }
        if a < 1_000_000 {
            let kw = a / 1000
            return Parts(value: kw, unit: "kW", direction: dir, text: fixed(kw, kw < 10 ? 1 : 0))
        }
        let mw = a / 1_000_000
        return Parts(value: mw, unit: "MW", direction: dir, text: fixed(mw, mw < 10 ? 2 : 1))
    }

    /// "4.2 kW", magnitude only.
    public static func text(_ watts: Double) -> String { parts(watts).joined }

    /// A chart rung: round by construction, so no forced decimal.
    public static func scale(_ watts: Double) -> String {
        guard watts.isFinite else { return "" }
        let a = abs(watts)
        if a < 1000 { return "\(Int(a.rounded())) W" }
        if a < 1_000_000 { return "\(trim(a / 1000)) kW" }
        return "\(trim(a / 1_000_000)) MW"
    }

    /// Permille on the wire, whole percent on screen.
    public static func soc(_ permille: Double) -> String {
        guard permille.isFinite else { return "—" }
        return String(Int((permille / 10).rounded()))
    }

    /// How old a reading is, coarse on purpose: a number ticking up every
    /// second draws the eye to the staleness rather than the reading.
    public static func age(_ ms: Double?) -> String {
        guard let ms, ms.isFinite, ms >= 0 else { return "unknown" }
        let s = Int(ms / 1000)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return "\(h) h ago" }
        return "\(h / 24) d ago"
    }

    /// JavaScript's toFixed, which rounds half away from zero on the
    /// decimal digits it keeps.
    public static func fixed(_ v: Double, _ digits: Int) -> String {
        let scale = pow(10, Double(digits))
        let r = (v * scale).rounded(.toNearestOrAwayFromZero) / scale
        return String(format: "%.\(digits)f", r)
    }

    static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r.rounded() == r ? String(Int(r)) : String(r)
    }
}

/// Energy in words. Watt-hours cross the wire and kilowatt-hours go on
/// screen, converted here and nowhere else, so the bars and the total over
/// them always add up.
public enum EnergyFormat {
    /// Integer watt-hours from whatever the box sent. Every daily figure is
    /// a magnitude, so a negative is a counter fault and reads as zero.
    public static func wholeWh(_ value: Double?) -> Double {
        guard let v = value, v.isFinite, v > 0 else { return 0 }
        return v.rounded()
    }

    /// "12.3" and "kWh": one decimal below ten, none above, as the box's page.
    public static func parts(_ wh: Double) -> (text: String, unit: String) {
        let kwh = wh / 1000
        return (PowerFormat.fixed(kwh, kwh < 10 ? 1 : 0), "kWh")
    }

    public static func label(_ wh: Double) -> String {
        let p = parts(wh)
        return "\(p.text) \(p.unit)"
    }

    /// Compact kWh for a bubble line, the dashboard's fmtKwhShort.
    public static func short(_ kwh: Double) -> String {
        let v = abs(kwh)
        if v >= 100 { return PowerFormat.fixed(kwh, 0) }
        if v >= 10 { return PowerFormat.fixed(kwh, 1) }
        return PowerFormat.fixed(kwh, 2)
    }
}
