import CoreGraphics
import Foundation

/// The price chart, worked out once per change of prices, plan or minute,
/// for the app and the widget alike. A price holds across its slot, so
/// each slot is a bar on a uniform grid that starts at the current slot.
/// Bars are ink by thirds of the window's range. It carries the average,
/// the cheapest two hours, now, tomorrow's slots still to come, and what a
/// finger reads on every slot, so a touch costs a subscript. A view only
/// maps it to its size.
public struct PriceChart: Equatable, Sendable {
    /// Which third of the window's range a price falls in: the dearer, the
    /// stronger the ink. No red and no green.
    public enum Third: Int, Equatable, Sendable {
        case cheap, middle, dear
    }

    /// An hour label on the time axis.
    public struct Tick: Equatable, Sendable {
        public var ms: Double
        public var label: String
    }

    public var grid: SlotGrid
    /// Minor units per kWh, per slot; nil where no price is published yet.
    public var minor: [Double?]
    /// The same in the unit the chart draws (öre, cent).
    public var shown: [Double?]
    public var thirds: [Third?]
    public var domain: YDomain
    /// The window's average, in the unit drawn, and as a figure: "101".
    public var meanShown: Double?
    public var meanText: String
    /// The cheapest two whole hours in a row inside the window.
    public var cheapest: ClosedRange<Int>?
    /// "CHEAPEST 00:00–02:00 · 28,5 ÖRE"
    public var cheapestText: String
    public var nowMs: Double
    public var nowIndex: Int?
    /// The slots at the end of the window that have no price yet.
    public var pending: ClosedRange<Int>?
    /// "TOMORROW ~13:00", over the pending slots.
    public var pendingText: String
    public var hours: [Tick]
    /// "öre/kWh"
    public var unit: String
    /// Per slot: "02:15–02:30".
    public var when: [String]
    /// Per slot: "31,0", never with a minus sign.
    public var figure: [String]
    /// Per slot, for the tag on the rule: "02:15  31,0 öre".
    public var tag: [String]
    /// Per slot: a negative price in words, and what the plan does then.
    public var doing: [String]
    /// What the plan does at these prices, in one mono line: the first time
    /// in the window the battery stores and the first it gives power, each
    /// with the prices it meets, `STORES 09:15–15:30 AT 58–90 · GIVES
    /// 17–20 AT 150–176 ÖRE`. Empty with no plan, or none for the battery.
    public var planLine: String
    /// The same with only its first part, for a width with no room for
    /// both: the line drops a part rather than end in "…".
    public var planLineShort: String
    public var currency: String
    /// The clock at each slot's edge: entry `i` starts slot `i`, the last
    /// ends the window.
    public var edges: [String]
    /// Prefix sums of the known prices and of how many there are, so two
    /// fingers' mean costs a subtraction.
    public var sums: [Double]
    public var counts: [Int]
    /// Slots that give a light impact under a finger: now, the cheapest
    /// window's edges, both ends, and each whole hour when the slots are
    /// shorter than an hour.
    public var landmarks: Set<Int>

    /// Whether any slot has a price.
    public var isEmpty: Bool { !minor.contains { $0 != nil } }

    /// The mean of the known prices between two fingers, in minor units.
    public func mean(_ r: ClosedRange<Int>) -> Double? {
        let lo = max(0, r.lowerBound), hi = min(minor.count - 1, r.upperBound)
        guard hi >= lo, counts[hi + 1] > counts[lo] else { return nil }
        return (sums[hi + 1] - sums[lo]) / Double(counts[hi + 1] - counts[lo])
    }

    /// "02:00–04:00", for two fingers.
    public func when(_ r: ClosedRange<Int>) -> String {
        edges[max(0, r.lowerBound)] + "–" + edges[min(edges.count - 1, r.upperBound + 1)]
    }

    /// "51,9", never with a minus sign.
    public func figure(_ minor: Double) -> String {
        Words.decimal(PriceStrip.text(abs(minor), currency))
    }

    /// The chart of `slots` across one window `spanMs` long: from `fromMs`
    /// where one is given, else from the slot now is in. A window behind
    /// now draws the same way, with no now rule and nothing pending.
    /// `everyHours` spaces the hour labels.
    public static func build(
        _ slots: [PriceSlot],
        currency: String,
        nowMs: Double,
        fromMs windowFromMs: Double? = nil,
        spanMs: Double = 24 * 3_600_000,
        everyHours: Int = 6,
        plan: PlanEntry? = nil,
        clock: ZoneClock
    ) -> PriceChart {
        let valid = slots.filter { $0.totalMinor.isFinite && $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
        let anchorMs = windowFromMs ?? nowMs
        let inWindow = valid.filter { $0.startMs + $0.durationMs > anchorMs && $0.startMs < anchorMs + spanMs }
        // One grid step for the window: the shortest slot in it, so an hour
        // of quarters and an hour slot sit on the same grid.
        let stepMs = max(60_000, inWindow.map(\.durationMs).min() ?? 900_000)
        let current = inWindow.first { $0.startMs <= anchorMs }
        let fromMs = windowFromMs.map { clock.alignDown($0, stepMs: stepMs) } ?? current?.startMs ?? clock.alignDown(nowMs, stepMs: stepMs)
        let count = max(1, Int((spanMs / stepMs).rounded(.up)))
        let toMs = fromMs + Double(count) * stepMs
        let grid = SlotGrid(firstMs: fromMs, stepMs: stepMs, count: count, fromMs: fromMs, toMs: toMs)

        var minor = [Double?](repeating: nil, count: count)
        for i in 0..<count {
            let ms = grid.startMs(i)
            guard let k = SlotLookup.clamped(valid, at: ms, start: \.startMs) else { break }
            let s = valid[k]
            if s.startMs <= ms, ms < s.startMs + s.durationMs { minor[i] = s.totalMinor }
        }
        let shown = minor.map { $0.map { PriceUnits.display($0, currency) } }
        let known = minor.compactMap { $0 }
        let lo = known.min() ?? 0, hi = known.max() ?? 0
        let third = (hi - lo) / 3
        let thirds: [Third?] = minor.map { v in
            guard let v else { return nil }
            guard hi > lo else { return .middle }
            return v < lo + third ? .cheap : v >= lo + 2 * third ? .dear : .middle
        }
        let shownKnown = shown.compactMap { $0 }
        let domain = YDomain.stable(low: min(0, shownKnown.min() ?? 0), high: max(0, shownKnown.max() ?? 0))
        let meanMinor = known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)

        let unit = PriceUnits.unit(currency)
        func figure(_ m: Double) -> String { Words.decimal(PriceStrip.text(abs(m), currency)) }
        func span(_ a: Double, _ b: Double) -> String { clock.label(a) + "–" + clock.label(b) }

        var cheapest: ClosedRange<Int>?
        var cheapestText = ""
        let inside = valid.filter { $0.startMs + $0.durationMs > fromMs && $0.startMs < toMs }
        if let block = PriceStrip.bestBlock(inside, hours: 2, cheapest: true),
           let a = grid.index(atMs: max(block.startMs, fromMs)), let b = grid.index(atMs: min(block.endMs, toMs) - 1) {
            cheapest = a...b
            cheapestText = PriceWord.cheapest.format(span(block.startMs, block.endMs), figure(block.meanMinor) + " " + unit.label.uppercased())
        }

        let nowIndex = nowMs >= fromMs && nowMs < toMs ? grid.index(atMs: nowMs) : nil

        var pending: ClosedRange<Int>?
        var pendingText = ""
        // Only a window that reaches past now can be waiting for rates. A
        // day behind with no price at its end is a hole, not a market yet
        // to speak.
        if toMs > nowMs, case .some(nil) = minor.last, let lastKnown = minor.lastIndex(where: { $0 != nil }) {
            pending = (lastKnown + 1)...(count - 1)
            if clock.minuteOfDay(grid.startMs(lastKnown + 1)) == 0 {
                pendingText = clock.minuteOfDay(nowMs) < 14 * 60 ? PriceWord.tomorrowAround.text : PriceWord.tomorrow.text
            }
        }

        // Whole local hours a few apart, clear of now's label and at least
        // an hour from the right edge. A window with no now in it has no
        // label to keep clear of.
        var hours: [Tick] = []
        let hour = 3_600_000.0
        var t = clock.alignDown(fromMs, stepMs: hour) + hour
        while t <= toMs - hour {
            let minute = clock.minuteOfDay(t)
            if minute % 60 == 0, (minute / 60) % max(1, everyHours) == 0, nowIndex == nil || t - nowMs >= 1.5 * hour {
                hours.append(Tick(ms: t, label: String(clock.label(t).prefix(2))))
            }
            t += hour
        }

        var when: [String] = [], figures: [String] = [], tags: [String] = [], doing: [String] = []
        when.reserveCapacity(count)
        figures.reserveCapacity(count)
        tags.reserveCapacity(count)
        doing.reserveCapacity(count)
        var landmarks: Set<Int> = [0, count - 1]
        if let nowIndex { landmarks.insert(nowIndex) }
        if let cheapest {
            landmarks.insert(cheapest.lowerBound)
            landmarks.insert(cheapest.upperBound)
        }
        // One label per edge: each slot ends where the next starts.
        let edges = (0...count).map { clock.label(grid.startMs($0)) }
        for i in 0..<count {
            let start = grid.startMs(i)
            // A firmer bump on the hour, when a slot is shorter than one.
            if stepMs < 3_600_000, clock.minuteOfDay(start) % 60 == 0 { landmarks.insert(i) }
            when.append(edges[i] + "–" + edges[i + 1])
            guard let m = minor[i] else {
                figures.append("—")
                tags.append(edges[i] + "  —")
                doing.append(PriceWord.noPriceYet.text)
                continue
            }
            let f = figure(m)
            figures.append(f)
            tags.append(edges[i] + "  " + f + " " + unit.label)
            var parts: [String] = m < 0 ? [PriceWord.paid.text] : []
            if let plan {
                parts += PlanGlance.events(plan, fromMs: start, toMs: start + stepMs).filter { $0.kind != .cheap }.prefix(2).map(PlanGlance.what)
            }
            doing.append(parts.joined(separator: " · "))
        }

        let planParts = plan.map { Self.planParts($0, grid: grid, minor: minor, currency: currency, clock: clock) } ?? []
        let unitWord = " " + PriceUnits.unit(currency).label.uppercased()
        let planLine = planParts.isEmpty ? "" : planParts.joined(separator: " · ") + unitWord
        let planLineShort = planParts.first.map { $0 + unitWord } ?? ""

        var sums = [0.0], counts = [0]
        for m in minor {
            sums.append(sums[sums.count - 1] + (m ?? 0))
            counts.append(counts[counts.count - 1] + (m == nil ? 0 : 1))
        }

        return PriceChart(
            grid: grid,
            minor: minor,
            shown: shown,
            thirds: thirds,
            domain: domain,
            meanShown: meanMinor.map { PriceUnits.display($0, currency) },
            meanText: meanMinor.map(figure) ?? "",
            cheapest: cheapest,
            cheapestText: cheapestText,
            nowMs: nowMs,
            nowIndex: nowIndex,
            pending: pending,
            pendingText: pendingText,
            hours: hours,
            unit: unit.perKwh,
            when: when,
            figure: figures,
            tag: tags,
            doing: doing,
            planLine: planLine,
            planLineShort: planLineShort,
            currency: currency,
            edges: edges,
            sums: sums,
            counts: counts,
            landmarks: landmarks
        )
    }

    /// The plan's first run of storing and of giving power inside the
    /// grid's window, in the order they come, each with the range of the
    /// prices under it in whole units.
    static func planParts(_ plan: PlanEntry, grid: SlotGrid, minor: [Double?], currency: String, clock: ZoneClock) -> [String] {
        let runs = PlanGlance.events(plan, fromMs: grid.fromMs, toMs: grid.toMs).filter { $0.kind == .charge || $0.kind == .discharge }
        var parts: [(startMs: Double, text: String)] = []
        for kind in [PlanGlance.Kind.charge, .discharge] {
            guard let e = runs.first(where: { $0.kind == kind }) else { continue }
            let a = max(e.startMs, grid.fromMs), b = min(e.endMs, grid.toMs)
            guard b > a else { continue }
            let prices = (0..<grid.count).filter { grid.startMs($0) < b && grid.endMs($0) > a }.compactMap { minor[$0] }
            guard let lo = prices.min(), let hi = prices.max() else { continue }
            func whole(_ m: Double) -> String { String(Int(PriceUnits.display(max(0, m), currency).rounded())) }
            let range = whole(lo) == whole(hi) ? whole(lo) : whole(lo) + "–" + whole(hi)
            let onHours = clock.minuteOfDay(a) % 60 == 0 && clock.minuteOfDay(b) % 60 == 0
            let span = onHours ? String(clock.label(a).prefix(2)) + "–" + String(clock.label(b).prefix(2)) : clock.label(a) + "–" + clock.label(b)
            parts.append((a, (kind == .charge ? PriceWord.stores : PriceWord.gives).format(span, range)))
        }
        return parts.sorted { $0.startMs < $1.startMs }.map(\.text)
    }

    /// The same from the bars a summary or a widget moment already holds.
    public static func build(bars: [PriceStrip.Bar], currency: String, nowMs: Double, spanMs: Double = 24 * 3_600_000, everyHours: Int = 6, plan: PlanEntry? = nil, clock: ZoneClock) -> PriceChart {
        build(bars.map { PriceSlot(startMs: $0.startMs, durationMs: $0.endMs - $0.startMs, spotMinor: $0.minor, totalMinor: $0.minor) }, currency: currency, nowMs: nowMs, spanMs: spanMs, everyHours: everyHours, plan: plan, clock: clock)
    }
}

/// The price chart's words. The English is the key; the Swedish lives in
/// `Resources/sv.lproj/Price.strings`, and a test checks each one has it.
enum PriceWord: String, CaseIterable {
    case cheapest = "CHEAPEST %@ · %@"
    case average = "AVG"
    case now = "NOW"
    case tomorrowAround = "TOMORROW ~13:00"
    case tomorrow = "TOMORROW"
    case noPriceYet = "No price yet"
    case paid = "Below zero: you are paid to use power"
    case stores = "STORES %@ AT %@"
    case gives = "GIVES %@ AT %@"
    /// History's price row: the day's mean, its cheapest slot and when.
    case dayAverage = "Average %@ · lowest %@ at %@"
    case noPriceThatDay = "No prices for this day"
    case someMissing = "%@ with no price"

    var text: String { Words.bundle.localizedString(forKey: rawValue, value: rawValue, table: "Price") }

    func format(_ args: String...) -> String {
        var out = text
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}

extension PriceChart {
    /// "AVG", over the average's figure in the right gutter.
    public static var averageWord: String { PriceWord.average.text }
    /// "NOW", under the now rule.
    public static var nowWord: String { PriceWord.now.text }
    /// A negative price, in words.
    public static var paidWord: String { PriceWord.paid.text }
}
