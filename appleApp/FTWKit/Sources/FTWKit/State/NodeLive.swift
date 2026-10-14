import Foundation
import FTWShared

/// What a node's view says around its live trace: the status line under
/// the title, the footer that says how the reading reaches the phone and
/// how often the device reads, the line under the chart, and the hero's
/// second fact. Plain values, so each can be tested.
public enum NodeLive {
    /// "● LIVE · SUNGROW", "○ AS OF 14:05 · SUNGROW", "○ NO READING YET".
    /// The home has no device of its own: the box calculates it.
    public static func status(_ node: EnergyNode, _ f: NodeFreshness, nowMs: Double, zone: TimeZone) -> String {
        let source = node == .home ? NodeWords.text("CALCULATED") : f.sourceName.map { $0.uppercased() }
        func with(_ head: String) -> String { [head, source].compactMap { $0 }.joined(separator: " · ") }
        if f.live { return with("● " + NodeWords.text("LIVE")) }
        if f.srcState == .never && f.ageMs == nil { return "○ " + NodeWords.text("NO READING YET") }
        guard let age = f.ageMs else { return with("○ " + NodeWords.text("NOT LIVE")) }
        return with("○ " + NodeWords.format("AS OF %@", AppWords.clock(nowMs - age, zone: zone)))
    }

    /// "VIA RELAY · READS EVERY 1 S". A switch between the relay and FTW
    /// Cloud changes the first word and nothing else on the screen.
    public static func footer(_ carrier: CarrierKind, periodMs: Double?) -> String {
        let via: String
        switch carrier {
        case .relay: via = NodeWords.text("VIA RELAY")
        case .webrtc: via = NodeWords.text("VIA DIRECT LINK")
        case .cloud: via = NodeWords.text("VIA FTW CLOUD")
        case .cache: via = NodeWords.text("SAVED ON THIS PHONE")
        case .none: via = NodeWords.text("NOT CONNECTED")
        }
        guard let periodMs, carrier != .cache, carrier != .none else { return via }
        let seconds = max(1, Int((periodMs / 1000).rounded()))
        return via + " · " + NodeWords.format("READS EVERY %@ S", String(seconds))
    }

    /// Energy in and out of the site over the runs, up to `untilMs`, by
    /// joining readings with straight lines. A silence that broke the line
    /// counts for nothing.
    public static func energy(_ runs: [[LiveSample]], untilMs: Double = .infinity) -> (inWh: Double, outWh: Double) {
        var inWh = 0.0, outWh = 0.0
        for run in runs {
            for (a, b) in zip(run, run.dropFirst()) where a.t < untilMs {
                let end = min(b.t, untilMs)
                let vb = b.t > a.t ? a.v + (b.v - a.v) * (end - a.t) / (b.t - a.t) : b.v
                let wh = (a.v + vb) / 2 * (end - a.t) / 3_600_000
                if wh >= 0 { inWh += wh } else { outWh -= wh }
            }
        }
        return (inWh, outWh)
    }

    /// Five minutes hold little energy: "42 Wh" under a kilowatt hour, so
    /// the line never says 0.0 while the battery works.
    public static func energy(_ wh: Double) -> String {
        let a = max(0, wh)
        return a < 1_000 ? "\(Int(a.rounded()))\u{00A0}Wh" : AppWords.energy(a)
    }

    /// "5 min: charged 120 Wh · gave 50 Wh", in the node's own words.
    /// Watts as the node shows them: solar as what it makes.
    public static func range(_ node: EnergyNode, _ e: (inWh: Double, outWh: Double)) -> String {
        let a = energy(e.inWh), b = energy(e.outWh)
        switch node {
        case .solar: return NodeWords.format("5 min: made %@", a)
        case .battery: return NodeWords.format("5 min: charged %@ · gave %@", a, b)
        case .home: return NodeWords.format("5 min: used %@", a)
        case .grid: return NodeWords.format("5 min: bought %@ · sold %@", a, b)
        case .car: return NodeWords.format("5 min: charged %@", a)
        }
    }

    /// The same up to the finger: "so far".
    public static func soFar(_ node: EnergyNode, _ e: (inWh: Double, outWh: Double)) -> String {
        node.directions != nil
            ? NodeWords.format("↑ %@ ↓ %@ so far", energy(e.inWh), energy(e.outWh))
            : NodeWords.format("%@ so far", energy(e.inWh))
    }

    /// Between two fingers: "↑ 80 Wh ↓ 0 Wh".
    public static func between(_ node: EnergyNode, _ e: (inWh: Double, outWh: Double)) -> String {
        node.directions != nil ? NodeWords.format("↑ %@ ↓ %@", energy(e.inWh), energy(e.outWh)) : energy(e.inWh)
    }

    /// The grid's cost per hour at this moment's price: "≈ 2.94 kr/h", or
    /// what selling earns. An estimate, and it says so.
    public static func gridCost(watts: Double, priceMinor: Double?, currency: String) -> String? {
        guard let priceMinor, abs(watts) > Flow.idleW else { return nil }
        let perHour = abs(priceMinor * watts / 1000 / 100)
        let figure = AppWords.decimal(PowerFormat.fixed(perHour, perHour >= 100 ? 0 : 2)) + " " + GridGlance.currencyUnit(currency) + "/h"
        return watts > 0 ? "≈ " + figure : NodeWords.format("earns ≈ %@", figure)
    }

    /// "82 % of forecast", for the sun in this hour. Nil when the forecast
    /// says too little to compare.
    public static func solarShare(madeW: Double, forecastW: Double?) -> String? {
        guard let forecastW, forecastW > 100, madeW >= 0 else { return nil }
        return NodeWords.format("%@ of forecast", AppWords.percent((madeW / forecastW * 100).rounded()))
    }

    /// Where the home's power comes from this second, as shares of one:
    /// the sun, the battery and the grid. Signs as the box gives them.
    public static func homeShares(pvW: Double, batteryW: Double, gridW: Double) -> (sun: Double, battery: Double, grid: Double)? {
        let sun = max(0, -pvW), battery = max(0, -batteryW), grid = max(0, gridW)
        let total = sun + battery + grid
        guard total > Flow.idleW else { return nil }
        return (sun / total, battery / total, grid / total)
    }

    /// The hero's word under a finger: "14:31:42 · giving power".
    public static func when(_ ms: Double, _ word: String) -> String {
        Readouts.seconds(ms) + " · " + word
    }

    /// The tag on the rule: "14:31:42  2 412 W".
    public static func tag(_ ms: Double, watts: Double) -> String {
        Readouts.seconds(ms) + "  " + AppWords.power(abs(watts))
    }
}

/// Which series a node's history shows: its own first, the others in Now's
/// order, and never none.
public enum SeriesPick {
    public static func ordered(_ series: [EnergyNode], own: EnergyNode) -> [EnergyNode] {
        let rest = EnergyNode.allCases.filter { $0 != own && series.contains($0) }
        return (series.contains(own) ? [own] : []) + rest
    }

    /// A tap on a chip: in or out, but the last one stays.
    public static func toggled(_ series: [EnergyNode], _ tapped: EnergyNode, own: EnergyNode) -> [EnergyNode] {
        if series.contains(tapped) {
            guard series.count > 1 else { return series }
            return ordered(series.filter { $0 != tapped }, own: own)
        }
        return ordered(series + [tapped], own: own)
    }

    /// What was kept, read back: unknown names dropped, the node's own
    /// series when nothing is left.
    public static func read(_ stored: String?, own: EnergyNode) -> [EnergyNode] {
        let kept = (stored ?? "").split(separator: ",").compactMap { EnergyNode(rawValue: String($0)) }
        return ordered(kept.isEmpty ? [own] : kept, own: own)
    }
}
