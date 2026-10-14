import CoreGraphics
import Foundation

/// The grid widget at one moment, worked out from a `GridTodayEntry` alone:
/// today's net energy with its direction and both sides of it, today's cost
/// as the box priced it, and the day as a chart on a fixed 00–24 axis, in
/// the app's grammar: one signed line with its body, buying above zero and
/// selling below, magenta both ways.
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
    /// The chart's scale never shrinks below a kilowatt each way it has,
    /// so a quiet day's noise stays small.
    public static let floorW: Double = 1_000

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
        /// "1,8": net, never signed; the word under it says which way.
        public let netText: String?
        public let unit: String
        /// "köpt netto", "sålt netto": which way the day leans, in words.
        public let netWord: String?
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
        /// The grid's net power each quarter the box has, signed as the
        /// site's watts: positive bought, negative sold. Nil where the box
        /// has no record. Nothing after the read: it has not happened.
        public let samples: [ChartSample]
        /// 00, 06, 12, 18, 24 on the household's clock.
        public let xTicks: [Tick]
        public let timeZone: TimeZone
        /// What VoiceOver reads for the whole widget.
        public let spoken: String

        public var isGrey: Bool { state != .today }
        public var hasChart: Bool { samples.contains { $0.value != nil } }

        /// The day's geometry on a plot of `size`, as the app draws a
        /// node's Today: one point per slot of at least 6 pt (60 minutes on
        /// the small widget, 30 on the medium), each the exact mean of its
        /// quarters, through a Steffen curve that never overshoots, with
        /// its body and the band of the quarters it holds. A hole the box
        /// has no record for stays a break.
        public func series(size: CGSize) -> ChartSeries {
            ChartSeries.history(
                samples,
                sampleMs: GridTodayEntry.quarterMs,
                fromMs: dayStartMs,
                toMs: dayEndMs,
                nowMs: readAtMs.map { min($0, dayEndMs) },
                size: size,
                floor: GridGlance.floorW,
                clock: ZoneClock.of(timeZone),
                words: ReadoutWords(value: { _ in "" }, range: { _, _ in "" }, none: "")
            )
        }
    }

    /// "↑ BUYING" over zero and "↓ SELLING" under it, where the chart has
    /// room on that side.
    public static func upWord(_ language: GridLanguage = .current) -> String { "↑ " + language.text(.buying) }
    public static func downWord(_ language: GridLanguage = .current) -> String { "↓ " + language.text(.selling) }

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

        let word: GridWord
        switch direction {
        case .fromGrid: word = .boughtNet
        case .toGrid: word = .soldNet
        case .even: word = .evenNet
        }

        return Moment(
            atMs: t, state: .today, readAtMs: read.record.readAtMs,
            direction: direction, netText: netText, unit: "kWh", netWord: language.text(word), inOutText: inOut,
            costText: cost?.shown, costUnit: unit, earned: cost?.isNegative ?? false,
            partial: partial, costNote: note, timeText: time, emptyText: nil,
            dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs,
            samples: samples(e.quarters, dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs),
            xTicks: xTicks(dayStartMs: e.dayStartMs, dayEndMs: e.dayEndMs, calendar: calendar),
            timeZone: calendar.timeZone, spoken: spoken.joined(separator: ". ")
        )
    }

    private static func empty(atMs t: Double, state: State, readAtMs: Double?, text: String, time: String?, day: (Double, Double), calendar: Calendar, language: GridLanguage) -> Moment {
        Moment(
            atMs: t, state: state, readAtMs: readAtMs, direction: .even, netText: nil, unit: "kWh", netWord: nil, inOutText: nil,
            costText: nil, costUnit: "", earned: false, partial: false, costNote: nil, timeText: time, emptyText: text,
            dayStartMs: day.0, dayEndMs: day.1, samples: [],
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

    /// Each quarter's net power, site-signed: what it bought less what it
    /// sold, both means over the part of the quarter the box recorded. A
    /// quarter without a record stays empty, so the line breaks there.
    static func samples(_ quarters: [GridTodayEntry.Quarter], dayStartMs: Double, dayEndMs: Double) -> [ChartSample] {
        quarters.filter { $0.startMs >= dayStartMs && $0.startMs < dayEndMs }.map { q in
            ChartSample(startMs: q.startMs, value: q.measured ? (q.importW ?? 0) - (q.exportW ?? 0) : nil)
        }
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
    case boughtNet = "bought, net"
    case soldNet = "sold, net"
    case evenNet = "even, net"
    case buying = "BUYING"
    case selling = "SELLING"
    case spokenFrom = "%@ kWh net from the grid today"
    case spokenTo = "%@ kWh net to the grid today"
    case spokenEven = "%@ kWh net with the grid today"
    case spokenCost = "cost %@"
    case spokenEarned = "earned %@"
}

