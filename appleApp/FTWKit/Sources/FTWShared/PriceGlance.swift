import Foundation

/// What a price widget shows at one moment, read from the cached prices and
/// nothing else.
///
/// A widget cannot ask the box anything, so its timeline is worked out in
/// advance: one moment now and one at every price boundary the box sent,
/// at whatever resolution the box sent it. Where the prices stop, the last
/// moment says so. It never stretches the last price over hours the market
/// has not priced, and never starts the day over with yesterday's.
public enum PriceGlance {
    /// How far ahead the medium widget's curve reaches.
    public static let curveMs: Double = 12 * 3_600_000
    /// The block strip's hours, on the small widget and the lock screen.
    public static let stripHours = 12

    /// What the box's total holds besides the market price. The wire has
    /// spot and total but not the settings between them, so this is read off
    /// the two figures: Core charges (spot + grid fee) × (1 + VAT).
    public enum Included: Equatable, Sendable {
        case gridFeeAndVAT, vat, gridFee
        /// The total is the market price and nothing else.
        case spotOnly
        /// Something is added, but the market barely moved, so a fee cannot
        /// be told from a percentage.
        case surcharges
    }

    public enum State: Equatable, Sendable {
        /// The app has left nothing: not paired, or signed out.
        case nothing
        /// A price covers this moment.
        case price
        /// No price covers this moment, and the next one starts at `nextMs`.
        case gap(nextMs: Double)
        /// No price covers this moment or anything after it.
        case ended(lastMs: Double)
    }

    public struct Moment: Equatable, Sendable {
        public let atMs: Double
        public let state: State
        /// `.cache` whenever there is a record: a file on this phone is not a
        /// connection to the box. `.none` when there is nothing.
        public let carrier: CarrierKind
        /// As it was when the app fetched the prices. Never better.
        public let srcState: SourceState
        /// Wall clock on the phone when the app fetched the prices.
        public let readAtMs: Double?
        public let currency: String
        public let current: PriceSlot?
        public let cheapest: PriceStrip.Block?
        /// Slots from the current one to `curveMs` ahead.
        public let curve: [PriceStrip.Bar]
        /// The next twelve hours as the block-glyph scale, from the hour
        /// that holds this moment.
        public let hours: [PriceBlocks.Hour]
        public let meanMinor: Double?
        public let included: Included

        /// "42.3", the price now. Nil when no price covers this moment.
        public let priceText: String?
        /// "öre/kWh"
        public let unitText: String
        /// "öre", for one short line.
        public let unitLabel: String
        /// "incl. grid fee and VAT"
        public let includedText: String
        /// "Cheapest 02–04"
        public let cheapestText: String?
        /// "cheapest 02:45": the start alone, for one short line.
        public let cheapestStartText: String?
        /// Why there is no price: "No prices after 24:00 · open FTW".
        public let emptyText: String?
        /// "Fetched 13:05"
        public let fetchedText: String?
        /// "AS OF 13:05": when the app fetched these prices, in the
        /// terminal's caps. A widget always says it.
        public let asOfText: String?
        /// The zone the clock in this moment is read in.
        public let timeZone: TimeZone

        /// Whether the widget should go grey: no price for this moment.
        public var isEmpty: Bool { state != .price }

        /// "▃▃▂▁▁▂▅▇█▆▅▄"
        public var glyphs: String { PriceBlocks.text(hours) }

        /// One line for the lock screen's inline slot, which shares its
        /// width with the date. Without a price it only sends the reader to
        /// the app; the other families say when the prices ended.
        public var inlineText: String {
            guard let priceText else { return GlanceWord.noPricesShort.text }
            let price = "\(priceText) \(unitLabel)"
            return cheapestStartText.map { "\(price) · \($0)" } ?? price
        }
    }

    /// The timeline: one moment now and one at every boundary ahead, the
    /// last where the prices end.
    public static func moments(_ read: CacheRead<PriceEntry>?, nowMs: Double, calendar given: Calendar? = nil) -> [Moment] {
        let calendar = given ?? .household(read?.value.timeZone)
        guard let read else { return [moment(nil, atMs: nowMs, calendar: calendar)] }
        // Sorted and read once, not once per moment.
        let slots = usable(read.value.prices)
        let included = included(slots)
        var edges = Set<Double>()
        for s in slots {
            edges.insert(s.startMs)
            edges.insert(s.startMs + s.durationMs)
        }
        let ahead = edges.filter { $0 > nowMs }.sorted()
        return ([nowMs] + ahead).map { moment(read, slots: slots, included: included, atMs: $0, calendar: calendar) }
    }

    /// The widget at one moment.
    public static func moment(_ read: CacheRead<PriceEntry>?, atMs t: Double, calendar given: Calendar? = nil) -> Moment {
        let calendar = given ?? .household(read?.value.timeZone)
        guard let read else {
            return Moment(
                atMs: t, state: .nothing, carrier: .none, srcState: .never, readAtMs: nil,
                currency: "", current: nil, cheapest: nil, curve: [], hours: [], meanMinor: nil, included: .spotOnly,
                priceText: nil, unitText: "", unitLabel: "", includedText: "", cheapestText: nil, cheapestStartText: nil,
                emptyText: GlanceWord.openToSee.text, fetchedText: nil, asOfText: nil, timeZone: calendar.timeZone
            )
        }
        let slots = usable(read.value.prices)
        return moment(read, slots: slots, included: included(slots), atMs: t, calendar: calendar)
    }

    private static func moment(_ read: CacheRead<PriceEntry>, slots: [PriceSlot], included: Included, atMs t: Double, calendar: Calendar) -> Moment {
        let prices = read.value.prices
        let unit = PriceUnits.unit(prices.currency)
        let current = slots.first { t >= $0.startMs && t < $0.startMs + $0.durationMs }

        let state: State
        if current != nil {
            state = .price
        } else if let next = slots.first(where: { $0.startMs > t }) {
            state = .gap(nextMs: next.startMs)
        } else {
            state = .ended(lastMs: slots.last.map { $0.startMs + $0.durationMs } ?? read.value.fromMs)
        }

        var cheapest: PriceStrip.Block?
        var curve: [PriceStrip.Bar] = []
        var mean: Double?
        if current != nil {
            let summary = PriceStrip.summary(Prices(zone: prices.zone, currency: prices.currency, slots: slots, stale: prices.stale), nowMs: t)
            cheapest = summary.cheapest
            curve = summary.bars.filter { $0.startMs < t + curveMs }
            mean = summary.meanMinor
        }

        let clock = Clock(calendar: calendar)
        var emptyText: String?
        switch state {
        case .nothing, .price: emptyText = nil
        case .gap(let next): emptyText = GlanceWord.noPriceUntil.format(clock.at(next, asEnd: false, from: t))
        case .ended(let last):
            // A box that sent no slots at all has no last hour to name.
            emptyText = slots.isEmpty ? GlanceWord.openToSee.text : GlanceWord.noPricesAfter.format(clock.at(last, asEnd: true, from: t))
        }

        return Moment(
            atMs: t,
            state: state,
            carrier: read.carrier,
            srcState: read.srcState,
            readAtMs: read.record.readAtMs,
            currency: prices.currency,
            current: current,
            cheapest: cheapest,
            curve: curve,
            hours: PriceBlocks.hours(curve, nowMs: t, count: stripHours, clock: ZoneClock.of(calendar.timeZone)),
            meanMinor: mean,
            included: included,
            priceText: current.map { Words.decimal(PriceStrip.text($0.totalMinor, prices.currency)) },
            unitText: unit.perKwh,
            unitLabel: unit.label,
            includedText: text(included),
            cheapestText: cheapest.map { clock.cheapest($0, from: t) },
            cheapestStartText: cheapest.map { clock.cheapestStart($0, from: t) },
            emptyText: emptyText,
            fetchedText: GlanceWord.fetched.format(clock.at(read.record.readAtMs, asEnd: false, from: t)),
            asOfText: GlanceWord.asOf.format(clock.at(read.record.readAtMs, asEnd: false, from: t).uppercased()),
            timeZone: calendar.timeZone
        )
    }

    /// What the total holds, from a straight line through (spot, total).
    /// Rounding to whole minor units blurs each point by half a unit, so the
    /// line needs some spread in spot before its slope means anything.
    public static func included(_ slots: [PriceSlot]) -> Included {
        guard !slots.isEmpty, slots.contains(where: { abs($0.totalMinor - $0.spotMinor) >= 1 }) else { return .spotOnly }
        let spots = slots.map(\.spotMinor)
        guard let lo = spots.min(), let hi = spots.max(), hi - lo >= 4 else { return .surcharges }
        let n = Double(slots.count)
        let mx = spots.reduce(0, +) / n
        let my = slots.map(\.totalMinor).reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for s in slots {
            sxx += (s.spotMinor - mx) * (s.spotMinor - mx)
            sxy += (s.spotMinor - mx) * (s.totalMinor - my)
        }
        let slope = sxy / sxx
        guard slope.isFinite, slope > 0 else { return .surcharges }
        let fee = (my - slope * mx) / slope
        switch (fee >= 1, slope > 1.03) {
        case (true, true): return .gridFeeAndVAT
        case (false, true): return .vat
        case (true, false): return .gridFee
        case (false, false): return .surcharges
        }
    }

    public static func text(_ included: Included) -> String {
        switch included {
        case .gridFeeAndVAT: return GlanceWord.inclGridFeeAndVAT.text
        case .vat: return GlanceWord.inclVAT.text
        case .gridFee: return GlanceWord.inclGridFee.text
        case .spotOnly: return GlanceWord.spotOnly.text
        case .surcharges: return GlanceWord.inclSurcharges.text
        }
    }

    /// The widget's name and line in the gallery.
    public static var title: String { GlanceWord.title.text }
    public static var summary: String { GlanceWord.summary.text }
    public static var priceNow: String { GlanceWord.priceNow.text }

    static func usable(_ prices: Prices) -> [PriceSlot] {
        prices.slots.filter { $0.totalMinor.isFinite && $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
    }
}

/// Every sentence a price widget shows. The English is the key, and the
/// Swedish lives in `Resources/sv.lproj`; a test checks each one has it.
enum GlanceWord: String, CaseIterable {
    case title = "Electricity price"
    case summary = "The price now and when it is cheapest next, from what FTW last fetched."
    case priceNow = "Price now"
    case cheapest = "Cheapest %@"
    case cheapestNow = "Cheapest now until %@"
    case tomorrow = "tomorrow %@"
    case cheapestStart = "cheapest %@"
    case cheapestStartNow = "cheapest now"
    case noPricesAfter = "No prices after %@ · open FTW"
    case noPriceUntil = "No price until %@ · open FTW"
    case openToSee = "Open FTW to see prices"
    case noPricesShort = "No prices · open FTW"
    case fetched = "Fetched %@"
    case asOf = "AS OF %@"
    case inclGridFeeAndVAT = "incl. grid fee and VAT"
    case inclVAT = "incl. VAT"
    case inclGridFee = "incl. grid fee"
    case spotOnly = "spot price only"
    case inclSurcharges = "incl. surcharges"

    var text: String { Words.text(rawValue) }

    func format(_ arg: String) -> String {
        String(format: text, arg)
    }
}

/// Times on the household's clock, 24-hour, as the box's own page writes
/// them. An end at midnight reads 24:00 of the day it ends, not 00:00 of the
/// next. A time on another day than the moment names that day, because a
/// widget can sit unread for days.
struct Clock {
    let calendar: Calendar

    struct Wall {
        let day: Date
        let hour: Int
        let minute: Int

        var hm: String { String(format: "%02d:%02d", hour, minute) }
    }

    func wall(_ ms: Double, asEnd: Bool) -> Wall {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let day = calendar.startOfDay(for: date)
        if asEnd, c.hour == 0, c.minute == 0, let before = calendar.date(byAdding: .day, value: -1, to: day) {
            return Wall(day: before, hour: 24, minute: 0)
        }
        return Wall(day: day, hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    func day(_ ms: Double) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000))
    }

    /// "13:05", or "Tue 24:00" when that is not the moment's day.
    func at(_ ms: Double, asEnd: Bool, from t: Double) -> String {
        let w = wall(ms, asEnd: asEnd)
        guard w.day != day(t) else { return w.hm }
        var named = calendar
        named.locale = Words.locale
        let weekday = named.component(.weekday, from: w.day)
        return "\(named.shortWeekdaySymbols[weekday - 1]) \(w.hm)"
    }

    /// "Cheapest 02–04", "Cheapest now until 04", "Cheapest tomorrow 15–17".
    ///
    /// Tomorrow is named only when the clock alone would read as today: at
    /// 20:00, "02–04" can only be tonight, but at 14:00 "15–17" looks like
    /// this afternoon.
    func cheapest(_ block: PriceStrip.Block, from t: Double) -> String {
        let a = wall(block.startMs, asEnd: false)
        let b = wall(block.endMs, asEnd: true)
        let whole = a.minute == 0 && b.minute == 0
        func short(_ w: Wall) -> String { whole ? String(format: "%02d", w.hour) : w.hm }
        if block.startMs <= t {
            return GlanceWord.cheapestNow.format(short(b))
        }
        let range = "\(short(a))–\(short(b))"
        return GlanceWord.cheapest.format(misleads(a, from: t) ? GlanceWord.tomorrow.format(range) : range)
    }

    /// "cheapest 02:45", "cheapest now", "cheapest tomorrow 15:00".
    func cheapestStart(_ block: PriceStrip.Block, from t: Double) -> String {
        if block.startMs <= t { return GlanceWord.cheapestStartNow.text }
        let a = wall(block.startMs, asEnd: false)
        return GlanceWord.cheapestStart.format(misleads(a, from: t) ? GlanceWord.tomorrow.format(a.hm) : a.hm)
    }

    /// A time tomorrow that the clock alone would read as later today.
    private func misleads(_ a: Wall, from t: Double) -> Bool {
        let now = wall(t, asEnd: false)
        return a.day > now.day && (a.hour, a.minute) > (now.hour, now.minute)
    }
}
