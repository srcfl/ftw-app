import Foundation

/// The grid widget at one moment, worked out from a `GridTodayEntry` alone:
/// today's net energy with its direction and both sides of it, today's cost
/// as the box priced it, and the day as a chart on a fixed 00–24 axis.
///
/// Net alone is never shown as if it were the bill: the line under it
/// always holds what was bought and what was sold. After local midnight a
/// record from yesterday is not today's, so the widget says today's figures
/// have not come yet rather than showing yesterday as today.
public enum GridGlance {
    /// The symbol beside the cost: the grid's own on Now (`NodeLook`), so
    /// one thing has one look. In the SDK since iOS 13.
    public static let symbol = "bolt.fill"
    /// Below this share of the day priced, the cost is marked partial.
    public static let fullCoverage = 0.95
    /// Below this a quarter's mean is sensor noise, as on Now.
    static let noiseW = PowerFormat.noiseW
    /// A side of the chart narrower than this share of it has no label.
    static let labelRoom = 0.2

    public enum State: Equatable, Sendable {
        /// The app has left nothing: not paired, or signed out.
        case nothing
        /// Today's figures, as of `readAtMs`.
        case today
        /// The record is from a day before this moment's: past midnight,
        /// before the app has read the new day.
        case newDay
    }

    /// Which way the day leans, net.
    public enum Direction: Equatable, Sendable {
        /// The home took more from the grid than it gave: ↓.
        case fromGrid
        /// It gave more than it took: ↑.
        case toGrid
        /// Even, to the tenth of a kWh.
        case even

        public var arrow: String {
            switch self {
            case .fromGrid: return "↓"
            case .toGrid: return "↑"
            case .even: return ""
            }
        }

        /// The SF Symbol for the arrow. Nil when even.
        public var symbol: String? {
            switch self {
            case .fromGrid: return "arrow.down"
            case .toGrid: return "arrow.up"
            case .even: return nil
            }
        }
    }

    /// One import bar: a quarter hour of mean power bought.
    public struct Bar: Equatable, Sendable, Identifiable {
        public let startMs: Double
        public let endMs: Double
        public let watts: Double
        public var id: Double { startMs }
    }

    /// One point of the export curve, at the middle of its quarter, in
    /// chart units: negative watts, so it sits below zero. `run` breaks the
    /// curve where the box has no record.
    public struct CurvePoint: Equatable, Sendable, Identifiable {
        public let t: Double
        public let watts: Double
        public let run: Int
        /// Two runs can share the zero between them.
        public var id: String { "\(run)/\(Int64(t))" }
    }

    /// A label on an axis, at a value in chart units.
    public struct Tick: Equatable, Sendable {
        public let value: Double
        public let label: String
    }

    public struct Moment: Equatable, Sendable {
        public let atMs: Double
        public let state: State
        /// When the app read these figures from the box.
        public let readAtMs: Double?

        public let direction: Direction
        /// "1,8": net, never signed; the arrow says which way.
        public let netText: String?
        public let unit: String
        /// "in 6,5 · ut 8,3 kWh"
        public let inOutText: String?
        /// "12,40" or "−4,20". Nil when the box had no prices.
        public let costText: String?
        /// "kr"
        public let costUnit: String
        /// The day so far earned more than it cost.
        public let earned: Bool
        /// The box priced less than `fullCoverage` of the day.
        public let partial: Bool
        /// "delvis", "inga priser", or nil.
        public let costNote: String?
        /// "kl 16:55", or "senast mån 23:55" once the day has turned.
        public let timeText: String?
        /// Why there is nothing for today.
        public let emptyText: String?

        /// The fixed axis: local midnight to the next.
        public let dayStartMs: Double
        public let dayEndMs: Double
        public let bars: [Bar]
        public let curve: [CurvePoint]
        /// The chart's value range: top above zero, bottom below.
        public let yTop: Double
        public let yBottom: Double
        /// 0 and at most one round value each way.
        public let yTicks: [Tick]
        /// 00, 06, 12, 18, 24 on the household's clock.
        public let xTicks: [Tick]
        public let timeZone: TimeZone
        /// What VoiceOver reads for the whole widget.
        public let spoken: String

        public var isGrey: Bool { state != .today }
        public var hasChart: Bool { !bars.isEmpty || !curve.isEmpty }
    }

    // MARK: The timeline

    /// One moment now and one at the next local midnight, where today's
    /// figures turn into yesterday's. The app reloads the timeline when it
    /// writes, so nothing here asks to be woken.
    public static func moments(_ read: CacheRead<GridTodayEntry>?, nowMs: Double, calendar given: Calendar? = nil, language: GridLanguage = .current) -> [Moment] {
        let calendar = given ?? .household(read?.value.timeZone)
        let now = moment(read, atMs: nowMs, calendar: calendar, language: language)
        guard read != nil, now.state == .today,
              let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000))) else { return [now] }
        return [now, moment(read, atMs: midnight.timeIntervalSince1970 * 1000, calendar: calendar, language: language)]
    }

    public static func moment(_ read: CacheRead<GridTodayEntry>?, atMs t: Double, calendar given: Calendar? = nil, language: GridLanguage = .current) -> Moment {
        let calendar = given ?? .household(read?.value.timeZone)
        guard let read else {
            let day = dayBounds(t, calendar: calendar)
            return empty(atMs: t, state: .nothing, readAtMs: nil, text: language.text(.openToSee), time: nil, day: day, calendar: calendar, language: language)
        }
        let e = read.value
        if e.day < GridTodayEntry.dayName(t, calendar: calendar) {
            let day = dayBounds(t, calendar: calendar)
            return empty(atMs: t, state: .newDay, readAtMs: read.record.readAtMs, text: language.text(.newDay),
                         time: language.format(.last, clockText(read.record.readAtMs, from: t, calendar: calendar, language: language)), day: day, calendar: calendar, language: language)
        }

        let format = Format(language: language)
        let netWh = e.importWh - e.exportWh
        let netText = format.kwh(abs(netWh))
        let direction: Direction = netText == format.kwh(0) ? .even : (netWh > 0 ? .fromGrid : .toGrid)
        let inOut = language.format(.inOut, format.kwh(e.importWh), format.kwh(e.exportWh))

        let cost = e.costMinor.map { format.money($0) }
        let partial = e.costMinor != nil && e.pricedCoverage < fullCoverage
        let note: String? = e.costMinor == nil ? language.text(.noPrices) : (partial ? language.text(.partial) : nil)
        let unit = currencyUnit(e.currency)

        let chart = chart(e.quarters, dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs)
        let time = language.format(.at, clockText(read.record.readAtMs, from: t, calendar: calendar, language: language))

        var spoken = [String]()
        switch direction {
        case .fromGrid: spoken.append(language.format(.spokenFrom, netText))
        case .toGrid: spoken.append(language.format(.spokenTo, netText))
        case .even: spoken.append(language.format(.spokenEven, netText))
        }
        spoken.append(inOut)
        if let cost {
            spoken.append(language.format(cost.isNegative ? .spokenEarned : .spokenCost, "\(cost.magnitude) \(unit)"))
        }
        if let note { spoken.append(note) }
        spoken.append(time)

        return Moment(
            atMs: t, state: .today, readAtMs: read.record.readAtMs,
            direction: direction, netText: netText, unit: "kWh", inOutText: inOut,
            costText: cost?.shown, costUnit: unit, earned: cost?.isNegative ?? false,
            partial: partial, costNote: note, timeText: time, emptyText: nil,
            dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs,
            bars: chart.bars, curve: chart.curve, yTop: chart.top, yBottom: chart.bottom, yTicks: chart.ticks,
            xTicks: xTicks(dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs, calendar: calendar),
            timeZone: calendar.timeZone, spoken: spoken.joined(separator: ". ")
        )
    }

    private static func empty(atMs t: Double, state: State, readAtMs: Double?, text: String, time: String?, day: (Double, Double), calendar: Calendar, language: GridLanguage) -> Moment {
        Moment(
            atMs: t, state: state, readAtMs: readAtMs, direction: .even, netText: nil, unit: "kWh", inOutText: nil,
            costText: nil, costUnit: "", earned: false, partial: false, costNote: nil, timeText: time, emptyText: text,
            dayStartMs: day.0, dayEndMs: day.1, bars: [], curve: [], yTop: 1, yBottom: -1, yTicks: [],
            xTicks: xTicks(dayStartMs: day.0, dayEndMs: day.1, calendar: calendar), timeZone: calendar.timeZone,
            spoken: [text, time].compactMap { $0 }.joined(separator: ". ")
        )
    }

    static func dayBounds(_ t: Double, calendar: Calendar) -> (Double, Double) {
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: t / 1000))
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }

    // MARK: The chart

    /// Bars for what was bought, a curve below zero for what was sold. A
    /// quarter without a record breaks the curve and has no bar; the curve
    /// is drawn only around export, resting on zero at each end of a run.
    static func chart(_ quarters: [GridTodayEntry.Quarter], dayStartMs: Double, dayEndMs: Double) -> (bars: [Bar], curve: [CurvePoint], top: Double, bottom: Double, ticks: [Tick]) {
        let q = GridTodayEntry.quarterMs
        let inDay = quarters.filter { $0.startMs >= dayStartMs && $0.startMs < dayEndMs }
        let bars = inDay.compactMap { r -> Bar? in
            guard let w = r.importW, w >= noiseW else { return nil }
            return Bar(startMs: r.startMs, endMs: min(dayEndMs, r.startMs + q), watts: w)
        }

        var curve = [CurvePoint]()
        var run = 0
        var open = false
        var previous: GridTodayEntry.Quarter?
        for r in inDay {
            // The quarter before has a record and touches this one.
            let joined = previous.map { $0.measured && $0.startMs + q == r.startMs } ?? false
            if !r.measured || !joined, open {
                // A hole: the run ends where the record does, off zero.
                open = false
                run += 1
            }
            if r.measured, (r.exportW ?? 0) >= noiseW {
                // A run leaves zero from the quarter before, when the box
                // has a record for it.
                if !open, joined, let p = previous { curve.append(CurvePoint(t: p.startMs + q / 2, watts: 0, run: run)) }
                open = true
                curve.append(CurvePoint(t: r.startMs + q / 2, watts: -(r.exportW ?? 0), run: run))
            } else if open {
                // and lands on zero at the first quarter that sold nothing.
                curve.append(CurvePoint(t: r.startMs + q / 2, watts: 0, run: run))
                open = false
                run += 1
            }
            previous = r
        }

        let peakIn = bars.map(\.watts).max() ?? 0
        let peakOut = curve.map { -$0.watts }.max() ?? 0
        let top = peakIn > 0 ? roundUp(peakIn) : 0
        let bottom = peakOut > 0 ? -roundUp(peakOut) : 0
        // A side with nothing on it keeps a sliver, so zero is not the edge.
        let span = max(top, -bottom, 1_000)
        let high = top > 0 ? top : span * 0.12
        let low = bottom < 0 ? bottom : -span * 0.12
        // A side too thin for its own label would print it on top of zero's.
        let room = labelRoom * (high - low)
        var ticks = [Tick]()
        if top > 0, top >= room { ticks.append(Tick(value: top, label: PowerFormat.scale(top))) }
        ticks.append(Tick(value: 0, label: "0"))
        if bottom < 0, -bottom >= room { ticks.append(Tick(value: bottom, label: PowerFormat.scale(bottom))) }
        return (bars, curve, high, low, ticks)
    }

    /// The next round value up: half a kilowatt below one, whole kilowatts
    /// to ten, then fives.
    static func roundUp(_ w: Double) -> Double {
        let kw = w / 1000
        if kw <= 0.5 { return 500 }
        if kw <= 10 { return kw.rounded(.up) * 1000 }
        return (kw / 5).rounded(.up) * 5000
    }

    /// 00, 06, 12, 18 and 24, on the household's clock, so a day that
    /// changes to or from summer time still puts noon at 12.
    static func xTicks(dayStartMs: Double, dayEndMs: Double, calendar: Calendar) -> [Tick] {
        let start = Date(timeIntervalSince1970: dayStartMs / 1000)
        var out = [0, 6, 12, 18].compactMap { h -> Tick? in
            guard let d = calendar.date(bySettingHour: h, minute: 0, second: 0, of: start) else { return nil }
            return Tick(value: d.timeIntervalSince1970 * 1000, label: String(format: "%02d", h))
        }
        out.append(Tick(value: dayEndMs, label: "24"))
        return out
    }

    /// "16:55" on the household's clock, or "mån 23:55" when that is not
    /// the moment's day: a widget can sit unread past midnight.
    static func clockText(_ ms: Double, from t: Double, calendar: Calendar, language: GridLanguage) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: t / 1000)) else { return hm }
        var named = calendar
        named.locale = language.locale
        return "\(named.shortWeekdaySymbols[named.component(.weekday, from: date) - 1]) \(hm)"
    }

    // MARK: Figures

    struct Money: Equatable {
        /// "−4,20", "12,40"
        let shown: String
        /// "4,20", for a sentence that names the direction in words.
        let magnitude: String
        let isNegative: Bool
    }

    struct Format {
        let language: GridLanguage

        /// One decimal, always, with the language's mark: "6,5", "12,0".
        func kwh(_ wh: Double) -> String {
            language.decimal(PowerFormat.fixed(max(0, wh) / 1000, 1))
        }

        /// Major units from minor: two decimals under a hundred, none from
        /// there. A minus sign, not a hyphen, and none on a zero.
        func money(_ minor: Double) -> Money {
            let a = abs(minor / 100)
            let digits = a >= 100 ? 0 : 2
            let figure = PowerFormat.fixed(a, digits)
            let body = language.decimal(figure)
            let negative = minor < 0 && figure != PowerFormat.fixed(0, digits)
            return Money(shown: (negative ? "−" : "") + body, magnitude: body, isNegative: negative)
        }
    }

    /// "kr" for the Nordic crowns, "€" for the euro, else the code.
    public static func currencyUnit(_ code: String) -> String {
        switch code.uppercased() {
        case "SEK", "NOK", "DKK", "": return "kr"
        case "EUR": return "€"
        default: return code.uppercased()
        }
    }

    public static func title(_ language: GridLanguage = .current) -> String { language.text(.title) }
    public static func summary(_ language: GridLanguage = .current) -> String { language.text(.summary) }
}

/// The language the grid widget speaks: Swedish or English, from the
/// package's own localisation, or named outright so a test can read both.
public struct GridLanguage: Equatable, Sendable {
    public let code: String

    public init(_ code: String) {
        self.code = code.lowercased().hasPrefix("sv") ? "sv" : "en"
    }

    public static var current: GridLanguage { GridLanguage(Words.locale.identifier) }
    public static let sv = GridLanguage("sv")
    public static let en = GridLanguage("en")

    var locale: Locale { Locale(identifier: code) }

    /// "6,5" in Swedish, "6.5" in English.
    func decimal(_ text: String) -> String {
        let mark = locale.decimalSeparator ?? "."
        return mark == "." ? text : text.replacingOccurrences(of: ".", with: mark)
    }

    func text(_ word: GridWord) -> String {
        let bundle = Words.bundle.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? Words.bundle
        return bundle.localizedString(forKey: word.rawValue, value: word.rawValue, table: "Grid")
    }

    func format(_ word: GridWord, _ args: String...) -> String {
        var out = text(word)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}

/// Every sentence the grid widget shows. The English is the key; the
/// Swedish lives in `Resources/sv.lproj/Grid.strings`, and a test checks
/// each one has it.
enum GridWord: String, CaseIterable {
    case title = "Grid today"
    case summary = "Today's energy from the grid and what it cost, as your box counted it."
    case inOut = "in %@ · out %@ kWh"
    case at = "at %@"
    case last = "last %@"
    case partial = "partial"
    case noPrices = "no prices"
    case openToSee = "Open FTW to see today's grid"
    case newDay = "Today's figures aren't here yet · open FTW"
    case spokenFrom = "%@ kWh net from the grid today"
    case spokenTo = "%@ kWh net to the grid today"
    case spokenEven = "%@ kWh net with the grid today"
    case spokenCost = "cost %@"
    case spokenEarned = "earned %@"
}

