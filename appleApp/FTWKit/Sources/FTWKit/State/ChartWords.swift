import Foundation
import FTWShared

/// What a chart says about the place under the finger: when, and what
/// happened or will happen there. It takes the place of the line under the
/// chart while the finger is down, and springs back when it lifts.
public struct ChartReadout: Equatable, Sendable {
    /// "14:35", or "13:00–15:30" for a range.
    public var when: String
    /// "1.2 kW charging · ↑ 3.4 kWh so far"
    public var what: String

    public init(when: String, what: String) {
        self.when = when
        self.what = what
    }
}

/// Readouts, worded the way the node's view words its figures.
public enum Readouts {
    /// "charging", "giving power", "making", "using", "buying", "selling".
    public static func word(_ node: EnergyNode, _ w: Double) -> String {
        if abs(w) <= Flow.idleW, node != .home { return NodeWords.text("resting") }
        switch node {
        case .solar: return NodeWords.text("making")
        case .battery: return w > 0 ? NodeWords.text("charging") : NodeWords.text("giving power")
        case .home: return NodeWords.text("using")
        case .grid: return w > 0 ? NodeWords.text("buying") : NodeWords.text("selling")
        case .car: return NodeWords.text("charging")
        }
    }

    public static func clock(_ ms: Double) -> String { AppWords.clock(ms, zone: .current) }

    public static func span(_ a: Double, _ b: Double) -> String { "\(clock(a))–\(clock(b))" }

    /// "14:35:12", for the live curve's seconds.
    public static func seconds(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// A step of history: its power and which way, and the energy since the
    /// chart's start up to the end of the step.
    public static func history(_ node: EnergyNode, _ samples: [HistorySample], fromMs: Double, at ms: Double) -> ChartReadout? {
        guard let i = samples.lastIndex(where: { $0.startMs <= ms }) else { return nil }
        let s = samples[i]
        let when = clock(max(fromMs, s.startMs))
        guard let w = s.watts else {
            return ChartReadout(when: when, what: s.fetching ? NodeWords.text("fetching…") : NodeWords.text("no data"))
        }
        let e = EnergyToday.sum(Array(samples[...i]), fromMs: fromMs)
        var what = "\(AppWords.power(abs(w))) \(word(node, w))"
        if node.directions != nil {
            what += " · " + NodeWords.format("↑ %@ ↓ %@ so far", AppWords.energy(e.inWh), AppWords.energy(e.outWh))
        } else {
            what += " · " + NodeWords.format("%@ so far", AppWords.energy(e.inWh))
        }
        return ChartReadout(when: when, what: what)
    }

    /// Two fingers on history: the mean power and the energy between them.
    public static func history(_ node: EnergyNode, _ samples: [HistorySample], range: ClosedRange<Double>) -> ChartReadout? {
        let inside = samples.filter { $0.startMs + $0.stepMs > range.lowerBound && $0.startMs < range.upperBound }
        guard !inside.isEmpty else { return nil }
        let e = EnergyToday.sum(inside, fromMs: range.lowerBound)
        let measured = inside.compactMap(\.watts)
        guard !measured.isEmpty else { return ChartReadout(when: span(range.lowerBound, range.upperBound), what: NodeWords.text("no data")) }
        let mean = measured.reduce(0, +) / Double(measured.count)
        var what = NodeWords.format("average %@", AppWords.power(abs(mean)))
        if node.directions != nil {
            what += " · " + NodeWords.format("↑ %@ ↓ %@", AppWords.energy(e.inWh), AppWords.energy(e.outWh))
        } else {
            what += " · " + AppWords.energy(e.inWh)
        }
        return ChartReadout(when: span(range.lowerBound, range.upperBound), what: what)
    }

    /// "65.5 öre/kWh"
    public static func price(_ minor: Double, _ currency: String) -> String {
        "\(AppWords.decimal(PriceStrip.text(minor, currency))) \(PriceUnits.unit(currency).perKwh)"
    }

    /// A slot ahead: what the plan does there and why, and the price.
    public static func ahead(_ node: EnergyNode, _ bars: [ChartSlot], _ prices: [ChartPrice], currency: String, forecast: Bool, at ms: Double) -> ChartReadout? {
        let bar = bars.first { $0.startMs <= ms && ms < $0.endMs }
        let price = prices.first { $0.startMs <= ms && ms < $0.endMs }
        guard bar != nil || price != nil else { return nil }
        let start = bar?.startMs ?? price!.startMs, end = bar?.endMs ?? price!.endMs
        var parts = [String]()
        if let bar {
            parts.append(forecast ? NodeWords.format("forecast %@", AppWords.power(abs(bar.watts))) : "\(word(node, bar.watts)) \(AppWords.power(abs(bar.watts)))")
            if let reason = bar.reason, abs(bar.watts) > Flow.idleW { parts.append(PlanText.reason(reason)) }
        } else {
            parts.append(NodeWords.text("nothing planned"))
        }
        if let price { parts.append(Self.price(price.minor, currency)) }
        return ChartReadout(when: span(start, end), what: parts.joined(separator: " · "))
    }

    /// Two fingers ahead: the energy the plan moves and the mean price.
    public static func ahead(_ node: EnergyNode, _ bars: [ChartSlot], _ prices: [ChartPrice], currency: String, forecast: Bool, range: ClosedRange<Double>) -> ChartReadout? {
        var inWh = 0.0, outWh = 0.0
        for b in bars {
            let covered = max(0, min(b.endMs, range.upperBound) - max(b.startMs, range.lowerBound))
            let wh = abs(b.watts) * covered / 3_600_000
            if b.watts >= 0 { inWh += wh } else { outWh += wh }
        }
        let inside = prices.filter { $0.endMs > range.lowerBound && $0.startMs < range.upperBound }
        var parts = [String]()
        parts.append(node.directions != nil ? NodeWords.format("↑ %@ ↓ %@", AppWords.energy(inWh), AppWords.energy(outWh)) : AppWords.energy(inWh))
        if !inside.isEmpty {
            parts.append(NodeWords.format("average %@", price(inside.map(\.minor).reduce(0, +) / Double(inside.count), currency)))
        }
        return ChartReadout(when: span(range.lowerBound, range.upperBound), what: parts.joined(separator: " · "))
    }

    /// An hour of the car's charging.
    public static func carHour(_ hours: [CarEnergyModel.Hour], at ms: Double) -> ChartReadout? {
        guard let h = hours.first(where: { $0.startMs <= ms && ms < $0.startMs + $0.lenMs }) else { return nil }
        return ChartReadout(when: span(h.startMs, h.startMs + h.lenMs), what: h.wh > 0 ? NodeWords.format("charged %@", AppWords.energy(h.wh)) : NodeWords.text("not charging"))
    }

    /// A price slot: the price, and what the plan does then. Past either
    /// edge it is the edge's slot, and in a gap the slot before it, as the
    /// stepped line draws it.
    public static func price(_ prices: [ChartPrice], currency: String, plan: PlanEntry?, at ms: Double) -> ChartReadout? {
        guard let i = SlotLookup.clamped(prices, at: ms, start: \.startMs) else { return nil }
        let slot = prices[i]
        var parts = [price(slot.minor, currency)]
        if let plan {
            let doing = PlanGlance.events(plan, fromMs: slot.startMs, toMs: slot.endMs).filter { $0.kind != .cheap }
            parts += doing.prefix(2).map(PlanGlance.what)
        }
        return ChartReadout(when: span(slot.startMs, slot.endMs), what: parts.joined(separator: " · "))
    }

    /// Two fingers on the prices: their mean between them.
    public static func price(_ prices: [ChartPrice], currency: String, range: ClosedRange<Double>) -> ChartReadout? {
        let inside = prices.filter { $0.endMs > range.lowerBound && $0.startMs < range.upperBound }
        guard !inside.isEmpty else { return nil }
        let mean = inside.map(\.minor).reduce(0, +) / Double(inside.count)
        return ChartReadout(when: span(range.lowerBound, range.upperBound), what: NodeWords.format("average %@", price(mean, currency)))
    }

    /// A moment of the live curve.
    public static func live(_ node: EnergyNode, _ points: [LiveTrace.Point], at ms: Double) -> ChartReadout? {
        guard let p = points.min(by: { abs($0.t - ms) < abs($1.t - ms) }), abs(p.t - ms) < LiveTrace.gapMs else {
            return ChartReadout(when: seconds(ms), what: NodeWords.text("no data"))
        }
        return ChartReadout(when: seconds(p.t), what: "\(AppWords.power(abs(p.v))) \(word(node, p.v))")
    }
}


/// A slot ahead as a chart draws it: when, the watts as the node shows
/// them, and the box's reason code.
public struct ChartSlot: Equatable, Sendable, Identifiable {
    public let startMs: Double
    public let endMs: Double
    /// Signed as the node shows it.
    public let watts: Double
    /// The box's reason code for the slot, when it gave one.
    public var reason: String?
    public var id: Double { startMs }

    public init(startMs: Double, endMs: Double, watts: Double, reason: String? = nil) {
        self.startMs = startMs
        self.endMs = endMs
        self.watts = watts
        self.reason = reason
    }
}

/// A price slot as a chart draws it, in minor units per kWh.
public struct ChartPrice: Equatable, Sendable, Identifiable {
    public let startMs: Double
    public let endMs: Double
    public let minor: Double
    public var id: Double { startMs }

    public init(startMs: Double, endMs: Double, minor: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.minor = minor
    }
}
