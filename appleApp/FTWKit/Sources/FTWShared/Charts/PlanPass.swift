import Foundation

/// One pass of the plan on a strip of quarters: a run of the battery giving
/// power or storing, or a window in which a car charges. A tap on Now's
/// strip, or on the plan, chooses one; the row of three figures under the
/// price then says when it runs, what it does to the level, and the price
/// it meets (Now, proposal 5 on the design canvas, picked by Fredrik on
/// 1 Nov 2026). The first says what it does and until when, "Laddar ur ·
/// till 09:45", or when a later one runs, "Laddar · 22:00–23:30" (Hannes,
/// 4 Nov 2026: clearer than "Nu"). Worked out with the strip, so a tap is
/// a lookup.
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
    /// For a battery run under way, the level the plan leads it to. The
    /// plan holds no level for now, so the level figure takes its start
    /// from the battery's reading (`figures(levelNow:)`).
    let underWayToPct: Double?
    public var id: String { "\(kind.rawValue)-\(Int64(startMs))" }

    /// The figures, with a run under way starting from the battery's level
    /// now: "58 → 10 %" where the plan alone says "→ 10 %".
    public func figures(levelNow: Double?) -> [Figure] {
        guard let to = underWayToPct, let now = levelNow, now.isFinite, figures.count > 1 else { return figures }
        var out = figures
        out[1] = Figure(title: out[1].title, tint: out[1].tint, value: Self.level(from: now, to: to), sub: out[1].sub)
        return out
    }

    /// "58 → 10 %".
    static func level(from a: Double, to b: Double) -> String { "\(Int(a.rounded())) → " + PlanGlance.percent(b) }

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
            // Only what overlaps the window: the grid clamps an index, so
            // an event outside it would land on its first or last quarter.
            guard e.endMs > grid.firstMs, e.startMs < grid.toMs else { return nil }
            guard let first = grid.index(atMs: max(e.startMs, grid.firstMs)),
                  let last = grid.index(atMs: min(e.endMs, grid.toMs) - 1), last >= first else { return nil }
            let prices = (first...last).compactMap { minor[$0] }
            let underWay = e.startMs <= nowMs + PlanGlance.graceMs
            let start = underWay ? PlanWord.now.text : clock.label(e.startMs)
            let until = PlanWord.until.format(clock.label(e.endMs))
            // When it runs, under the word for what it does: until its end
            // while it is under way, its start and end after.
            let when = underWay ? until : clock.label(e.startMs) + "–" + clock.label(e.endMs)
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
                let level = switch (before, e.endLevelPct) {
                case let (a?, b?): Self.level(from: a, to: b)
                case let (nil, b?): "→ " + PlanGlance.percent(b)
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
                    Figure(title: PlanWord.passBattery.text, tint: gives ? .gives : .stores, value: (gives ? PlanWord.passDischarges : PlanWord.passCharges).text, sub: when),
                    Figure(title: PlanWord.passLevel.text, tint: .ink, value: level, sub: PlanWord.passInAll.format(energy(wh))),
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
                    Figure(title: PlanWord.passCar.text, tint: .car, value: PlanWord.passCharges.text, sub: when),
                    goal,
                    Figure(title: PlanWord.passMeanPrice.text, tint: .ink, value: mean, sub: e.energyWh.map(energy) ?? ""),
                ]
                what = PlanWord.car.text + ", " + start.lowercased() + " " + until + ", " + goal.title.lowercased() + " " + goal.value
            }
            return PlanPass(kind: kind, startMs: e.startMs, endMs: e.endMs, first: first, last: last, figures: figures, spoken: what,
                            underWayToPct: kind != .car && underWay ? e.endLevelPct : nil)
        }
    }

    /// The pass a strip opens on: the battery's run under way or next,
    /// else the first car window.
    public static func opening(_ passes: [PlanPass]) -> PlanPass? {
        passes.first(where: \.isBattery) ?? passes.first
    }
}
