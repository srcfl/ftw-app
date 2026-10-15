import Foundation
import FTWShared

/// What a node's view says around its live trace: the footer that says how
/// the reading reaches the phone, from which device and how often it reads,
/// the line under the chart, and the hero's words and second fact. Plain
/// values, so each can be tested.
public enum NodeLive {
    /// The foot of a node's view: how the reading reaches the phone, the
    /// device behind it, and how often that device reads, as in "VIA RELAY
    /// · SUNGROW · READS EVERY 1 S". The home has no device of its own: the
    /// box calculates it. The status line under the title speaks for the
    /// whole home; while it gives the home's age (`titleSaysAge`) the footer
    /// does not repeat it. Otherwise a node that is not live starts with its
    /// own: "○ AS OF 14:05 · VIA RELAY · SUNGROW", a clock time, never a
    /// count of seconds. A switch between the relay and FTW Cloud changes the
    /// path's word and nothing else.
    public static func footer(_ node: EnergyNode, _ f: NodeFreshness, carrier: CarrierKind, periodMs: Double?, titleSaysAge: Bool, nowMs: Double, zone: TimeZone) -> String {
        let via: String
        switch carrier {
        case .relay: via = NodeWords.text("VIA RELAY")
        case .webrtc: via = NodeWords.text("VIA DIRECT LINK")
        case .cloud: via = NodeWords.text("VIA FTW CLOUD")
        case .cache: via = NodeWords.text("SAVED ON THIS PHONE")
        case .none: via = NodeWords.text("NOT CONNECTED")
        }
        let device = node == .home ? NodeWords.text("CALCULATED") : deviceName(f.sourceName)
        var parts = [via] + [device].compactMap { $0 }
        if !titleSaysAge && !f.live {
            let head: String
            if f.srcState == .never && f.ageMs == nil { head = NodeWords.text("NO READING YET") }
            else if let age = f.ageMs { head = NodeWords.format("AS OF %@", AppWords.clock(nowMs - age, zone: zone)) }
            else { head = NodeWords.text("NOT LIVE") }
            // A device that is not live reads at no cadence worth naming.
            return (["○ " + head] + parts).joined(separator: " · ")
        }
        if let periodMs, carrier != .cache, carrier != .none {
            let seconds = max(1, Int((periodMs / 1000).rounded()))
            parts.append(NodeWords.format("READS EVERY %@ S", String(seconds)))
        }
        return parts.joined(separator: " · ")
    }

    /// The device as the box names it, in the footer's caps: "sungrow_sh10"
    /// reads "SUNGROW SH10". Nil when the box gives no name.
    public static func deviceName(_ name: String?) -> String? {
        let words = (name ?? "").split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        return words.isEmpty ? nil : words.joined(separator: " ").uppercased()
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

    /// The sun's outlook from the forecast the box already sent: "11 kWh
    /// expected" for the rest of today while it shines, and "sun from about
    /// 07:45" while it is down or nearly gone. Nil with no forecast, so the
    /// view invents nothing.
    public static func solarOutlook(_ forecast: [PlanModel.Forecast], nowMs: Double, zone: TimeZone) -> String? {
        let ahead = forecast.filter { $0.startMs + $0.durationMs > nowMs }.sorted { $0.startMs < $1.startMs }
        // A plan made this minute may start a few seconds from now; one
        // that starts more than a slot away says nothing of the sun now.
        guard let current = ahead.first, current.startMs - nowMs < max(current.durationMs, 60_000) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date(timeIntervalSince1970: nowMs / 1000)
        let midnightMs = (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))?.timeIntervalSince1970 ?? 0) * 1000
        let restWh = ahead.reduce(0.0) { sum, slot in
            let from = max(slot.startMs, nowMs), to = min(slot.startMs + slot.durationMs, midnightMs)
            return to > from ? sum + slot.pvW * (to - from) / 3_600_000 : sum
        }
        if current.pvW > Flow.idleW, restWh >= 100 {
            return NodeWords.format("%@ expected", AppWords.energy(restWh))
        }
        // The next rise: the first slot with sun after the dark one now or
        // the next one to come.
        let dark = current.pvW > Flow.idleW ? ahead.firstIndex { $0.pvW <= Flow.idleW } : 0
        guard let dark, let rise = ahead[dark...].first(where: { $0.pvW > Flow.idleW }) else { return nil }
        return NodeWords.format("sun from about %@", AppWords.clock(rise.startMs, zone: zone))
    }

    /// The hero's words over two fingers on the live trace, short enough to
    /// keep one size on one line: "05:44–05:47 · avg 437 W", or "05:44 · avg
    /// 437 W" inside one minute. The tag on the chart keeps the seconds.
    public static func spanWords(fromMs: Double, toMs: Double, meanW: Double, zone: TimeZone) -> String {
        let a = AppWords.clock(fromMs, zone: zone), b = AppWords.clock(toMs, zone: zone)
        return (a == b ? a : a + "–" + b) + " · " + NodeWords.format("avg %@", AppWords.power(abs(meanW)))
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
