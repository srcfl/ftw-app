import Foundation

/// One pass of the plan on a strip of quarters: a run of the battery giving
/// power or storing, or a window in which a car charges. A tap on Now's
/// strip, or on the plan, chooses one; the row of three figures under the
/// price then says when it runs, what it does to the level, and the price
/// it meets (Now, proposal 5 on the design canvas, picked by Fredrik on
/// 1 Nov 2026). Worked out with the strip, so a tap is a lookup.
public struct PlanPass: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case gives, stores, car
    }

    /// One of the three figures: a mono title, a figure and a line under it.
    public struct Figure: Equatable, Sendable {
        /// The title's ink: the pass's colour for the first, ink2 after.
        public enum Tint: Equatable, Sendable {
            case gives, stores, car, ink
        }

        public let title: String
        public let tint: Tint
        public let value: String
        public let sub: String
    }

    public let kind: Kind
    public let startMs: Double
    public let endMs: Double
    /// The quarters of the strip it covers, cut to the strip.
    public let first: Int
    public let last: Int
    /// When it runs, what it does to the level, and the price it meets.
    public let figures: [Figure]
    /// The pass in one line, for VoiceOver.
    public let spoken: String
    public var id: String { "\(kind.rawValue)-\(Int64(startMs))" }

    public var isBattery: Bool { kind != .car }

    /// The passes in a strip's window, in order: each battery run and each
    /// car window that ends after `nowMs` and starts before the strip ends.
    /// `minor` is the strip's price per quarter, so a pass's prices are the
    /// ones its bars draw.
    public static func passes(_ entry: PlanEntry?, grid: SlotGrid, nowMs: Double, minor: [Double?], clock: ZoneClock) -> [PlanPass] {
        guard let entry else { return [] }
        let currency = entry.currency
        let unit = PriceUnits.unit(currency).label
        let slots = (entry.battery ?? []).sorted { $0.startMs < $1.startMs }
        func price(_ m: Double) -> String { PriceStrip.whole(m, currency) + " " + unit }
        func energy(_ wh: Double) -> String { Words.decimal(EnergyFormat.label(wh)) }

        return PlanGlance.events(entry, fromMs: nowMs, toMs: grid.toMs).compactMap { e -> PlanPass? in
            let kind: Kind
            switch e.kind {
            case .discharge: kind = .gives
            case .charge: kind = .stores
            case .car: kind = .car
            case .cheap: return nil
            }
            guard let first = grid.index(atMs: max(e.startMs, grid.firstMs)),
                  let last = grid.index(atMs: min(e.endMs, grid.toMs) - 1), last >= first else { return nil }
            let prices = (first...last).compactMap { minor[$0] }
            let underWay = e.startMs <= nowMs + PlanGlance.graceMs
            let start = underWay ? PlanWord.now.text : clock.label(e.startMs)
            let until = PlanWord.until.format(clock.label(e.endMs))
            let top = prices.max().map(price) ?? "—"
            let mean = prices.isEmpty ? "—" : price(prices.reduce(0, +) / Double(prices.count))

            var figures: [Figure]
            var what: String
            switch kind {
            case .gives, .stores:
                // The energy the run moves from now on, and the level it
                // starts at where the plan says one: the slot that ends as
                // it starts.
                var wh = 0.0
                for s in slots where s.startMs < e.endMs && s.startMs + s.durationMs > max(e.startMs, nowMs) {
                    let overlap = min(e.endMs, s.startMs + s.durationMs) - max(s.startMs, e.startMs, nowMs)
                    wh += abs(s.batteryW) * max(0, overlap) / 3_600_000
                }
                let before = underWay ? nil : slots.last { abs($0.startMs + $0.durationMs - e.startMs) < 1 }?.levelPct
                let to = e.endLevelPct.map(PlanGlance.percent)
                let level = switch (before, to) {
                case let (a?, b?): "\(Int(a.rounded())) → " + b
                case let (nil, b?): "→ " + b
                default: "—"
                }
                let gives = kind == .gives
                let third: Figure
                if gives {
                    third = Figure(title: PlanWord.passTopPrice.text, tint: .ink, value: top, sub: PlanWord.passDuring.text)
                } else if e.reason == "solar_surplus" {
                    third = Figure(title: PlanWord.passSource.text, tint: .ink, value: PlanWord.passSun.text, sub: PlanWord.passNoPurchase.text)
                } else {
                    third = Figure(title: PlanWord.passMeanPrice.text, tint: .ink, value: mean, sub: PlanWord.passFromGrid.text)
                }
                figures = [
                    Figure(title: PlanWord.passBattery.text, tint: gives ? .gives : .stores, value: start, sub: until),
                    Figure(title: PlanWord.passLevel.text, tint: .ink, value: level, sub: (gives ? PlanWord.passGivesEnergy : PlanWord.passStoresEnergy).format(energy(wh))),
                    third,
                ]
                what = (gives ? PlanWord.batteryGiving : PlanWord.batteryCharging).text
                    + ", " + start.lowercased() + " " + until + ", " + third.title.lowercased() + " " + third.value
            case .car:
                let goal: Figure
                if let pct = e.targetPct {
                    let by = e.goalMs.map { PlanWord.passReadyBy.format(clock.label($0)) } ?? (e.chargesAgain ? PlanWord.passAgainLater.text : "")
                    goal = Figure(title: PlanWord.passGoal.text, tint: .ink, value: (e.chargesAgain ? PlanWord.passToward.format(PlanGlance.percent(pct)) : PlanGlance.percent(pct)), sub: by)
                } else {
                    goal = Figure(title: PlanWord.passGoal.text, tint: .ink, value: "—", sub: "")
                }
                figures = [
                    Figure(title: PlanWord.passCar.text, tint: .car, value: start, sub: until),
                    goal,
                    Figure(title: PlanWord.passMeanPrice.text, tint: .ink, value: mean, sub: e.energyWh.map(energy) ?? ""),
                ]
                what = PlanWord.car.text + ", " + start.lowercased() + " " + until + ", " + goal.title.lowercased() + " " + goal.value
            }
            return PlanPass(kind: kind, startMs: e.startMs, endMs: e.endMs, first: first, last: last, figures: figures, spoken: what)
        }
    }

    /// The pass a strip opens on: the battery's run under way or next,
    /// else the first car window.
    public static func opening(_ passes: [PlanPass]) -> PlanPass? {
        passes.first(where: \.isBattery) ?? passes.first
    }
}
