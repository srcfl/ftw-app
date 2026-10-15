import Foundation
import FTWShared

/// What the box says the home saved, from `GET /api/savings/daily`, as the
/// box gave it. A day is the box's row; a week or a month is the box's own
/// totals for that many days. The app adds no money up itself.
///
/// The comparison is the box's `baseline_cost_ore`: the same use bought
/// from the grid with no solar and no battery. The box also sends a
/// self-consumption baseline, and it is not read: that baseline drains the
/// battery and can read cheaper than what FTW did, so it would call a good
/// day a loss.
public enum Savings {
    /// The share of a span's time the box must have priced for its money to
    /// stand without "partial".
    public static let wholeCoverage = 0.95

    public enum Period: String, CaseIterable, Codable, Sendable {
        case day, week, month

        public var label: String {
            switch self {
            case .day: return AppWords.text("Day")
            case .week: return AppWords.text("Week")
            case .month: return AppWords.text("Month")
            }
        }
    }

    /// One day's row, or a span's totals, in the box's own figures.
    public struct Figures: Codable, Equatable, Sendable {
        /// "2026-10-15"; empty for a span's totals.
        public var day: String
        /// Whether the box had any price for it. Without one, no money is
        /// shown.
        public var priced: Bool
        public var savedMinor: Double
        public var actualMinor: Double
        public var baselineMinor: Double
        /// What buying cost and what selling paid. The box gives these per
        /// day, not in its totals.
        public var boughtMinor: Double?
        public var soldMinor: Double?
        public var importWh: Double
        public var exportWh: Double
        /// The share of the time the box had a price for, 0 to 1.
        public var pricedCoverage: Double

        public var partial: Bool { priced && pricedCoverage < Savings.wholeCoverage }
    }

    /// One answer: the days oldest first, and the box's totals for them.
    public struct Answer: Codable, Equatable, Sendable {
        public var days: [Figures]
        public var totals: Figures?
        /// The box's zone, which names its days.
        public var tz: String?

        public init(days: [Figures], totals: Figures?, tz: String?) {
            self.days = days
            self.totals = totals
            self.tz = tz
        }
    }

    /// The box's answer. A box with no price area answers no days at all.
    public static func answer(_ wire: JSON?) -> Answer {
        let days = (wire?["days"]?.array ?? []).compactMap { row -> Figures? in
            guard let day = row["day"]?.string, dayParts(day) != nil else { return nil }
            return figures(row, day: day, priced: row["resolution"]?.string != "no_prices")
        }
        .sorted { $0.day < $1.day }
        let totals = wire?["totals"].flatMap { $0.object == nil ? nil : figures($0, day: "", priced: days.contains(where: \.priced)) }
        return Answer(days: days, totals: days.isEmpty ? nil : totals, tz: wire?["tz"]?.string)
    }

    static func figures(_ row: JSON, day: String, priced: Bool) -> Figures {
        func n(_ key: String) -> Double { row[key]?.number.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        func maybe(_ key: String) -> Double? { row[key]?.number.flatMap { $0.isFinite ? $0 : nil } }
        return Figures(
            day: day,
            priced: priced,
            savedMinor: n("saved_ore"),
            actualMinor: n("actual_cost_ore"),
            baselineMinor: n("baseline_cost_ore"),
            boughtMinor: maybe("import_cost_ore"),
            soldMinor: maybe("export_revenue_ore"),
            importWh: max(0, n("import_wh")),
            exportWh: max(0, n("export_wh")),
            pricedCoverage: min(1, max(0, n("priced_coverage_pct")))
        )
    }

    /// "2026-10-15" as year, month and day.
    static func dayParts(_ day: String) -> DateComponents? {
        let p = day.split(separator: "-")
        guard day.count == 10, p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), (1...12).contains(m), (1...31).contains(d) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    /// The day `ms` falls on, on `calendar`: "2026-10-15".
    public static func dayName(_ ms: Double, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// How many days the month so far holds on `calendar`, today included.
    public static func monthDays(_ ms: Double, calendar: Calendar) -> Int {
        calendar.component(.day, from: Date(timeIntervalSince1970: ms / 1000))
    }
}

// MARK: - What the screen says

/// The savings screen as values: the hero, two reserved lines under the
/// chart, the bars and the footer, for one period. Built once per change
/// of answer, period or minute. Every figure is the box's.
public struct SavingsGlance: Equatable, Sendable {
    /// What the hero and the two lines say, for the period or for one day
    /// under a finger.
    public struct Reading: Equatable, Sendable {
        /// "18,40", or "—" when the box has no money to say.
        public var figure: String
        public var unit: String
        /// "Saved today so far", "Cost more 9–15 Oct"
        public var word: String
        /// "PARTIAL" when the box had prices for less than 95 % of the time.
        public var kicker: String?
        /// The figure is the box's money, not a dash.
        public var known: Bool
        /// Two lines at most.
        public var lines: [String]
    }

    public var period: Savings.Period
    public var reading: Reading
    public var chart: SavingsChart
    /// "AS OF 14:32", mono.
    public var footer: String
    /// Nothing from the box yet: the shape of the screen, redacted.
    public var placeholder: Bool

    /// The period from the answer that holds it: the day and the week from
    /// the last seven days, the month from the month so far.
    public static func make(period: Savings.Period, answer: Stamped<Savings.Answer>?, problem: String? = nil, nowMs: Double, currency: String) -> SavingsGlance {
        guard let answer else { return waiting(period, problem: problem, currency: currency) }
        let a = answer.value
        let zone = EVText.householdZone(boxTZ: a.tz)
        let calendar = EVText.calendar(zone)
        let money = SavingsMoney(currency: currency)
        let today = Savings.dayName(nowMs, calendar: calendar)
        let footer = Self.footer(answer, nowMs: nowMs, zone: zone)
        guard let last = a.days.last else {
            let reading = Reading(figure: "—", unit: money.unit, word: AppWords.text("Savings"), kicker: nil, known: false,
                                  lines: [AppWords.text("Your box counts savings once it knows your price area.")])
            return SavingsGlance(period: period, reading: reading, chart: .empty, footer: footer, placeholder: false)
        }
        let chart = SavingsChart.make(a.days, focus: period == .day ? a.days.count - 1 : nil, today: today, calendar: calendar, money: money)
        let reading: Reading
        switch period {
        case .day:
            reading = Self.reading(last, when: Self.when(day: last.day, today: today, calendar: calendar), money: money)
        case .week, .month:
            let first = a.days.first?.day ?? last.day
            let span = first == last.day ? Self.when(day: last.day, today: today, calendar: calendar) : Self.range(first, last.day, calendar: calendar)
            if let totals = a.totals {
                reading = Self.reading(totals, when: span, money: money)
            } else {
                let word = span.isToday ? AppWords.text("Saved today so far") : AppWords.format("Saved %@", span.text)
                reading = Reading(figure: "—", unit: money.unit, word: word, kicker: nil, known: false, lines: [])
            }
        }
        return SavingsGlance(period: period, reading: reading, chart: chart, footer: footer, placeholder: false)
    }

    /// What the hero and the lines say for one row or one span's totals.
    static func reading(_ f: Savings.Figures, when: Phrase, money: SavingsMoney) -> Reading {
        guard f.priced else {
            let word = when.isToday ? AppWords.text("Saved today so far") : AppWords.format("Saved %@", when.text)
            return Reading(figure: "—", unit: money.unit, word: word, kicker: nil, known: false,
                           lines: [AppWords.text("The box had no prices then, so it counts no money.")])
        }
        let more = f.savedMinor < 0 && money.figure(f.savedMinor) != money.figure(0)
        let word: String
        switch (more, when.isToday) {
        case (false, true): word = AppWords.text("Saved today so far")
        case (true, true): word = AppWords.text("Cost more today so far")
        case (false, false): word = AppWords.format("Saved %@", when.text)
        case (true, false): word = AppWords.format("Cost more %@", when.text)
        }
        let cost = f.actualMinor < 0 && money.figure(f.actualMinor) != money.figure(0)
            ? AppWords.format("Earned %@", money.text(f.actualMinor))
            : AppWords.format("Cost %@", money.text(f.actualMinor))
        var lines = [cost + " · " + AppWords.format("with no solar or battery %@", money.text(f.baselineMinor))]
        if f.partial {
            lines.append(AppWords.format("The box had prices for %@ of the time.", AppWords.percent(f.pricedCoverage * 100)))
        } else if let bought = f.boughtMinor, let sold = f.soldMinor {
            lines.append(AppWords.format("Bought for %@, sold for %@", money.text(bought), money.text(sold)))
        } else {
            lines.append(AppWords.format("Bought %@, sold %@", AppWords.energy(f.importWh), AppWords.energy(f.exportWh)))
        }
        return Reading(figure: money.figure(f.savedMinor), unit: money.unit, word: word,
                       kicker: f.partial ? AppWords.text("PARTIAL") : nil, known: true, lines: lines)
    }

    /// A day or a span, in words for the hero.
    struct Phrase: Equatable {
        var text: String
        var isToday = false
    }

    /// "today so far" for today, else "Tue 14 Oct".
    static func when(day: String, today: String, calendar: Calendar) -> Phrase {
        if day == today { return Phrase(text: "", isToday: true) }
        return Phrase(text: dayText(day, calendar: calendar))
    }

    /// "Tue 14 Oct" / "tis 14 okt".
    static func dayText(_ day: String, calendar: Calendar) -> String {
        guard let parts = Savings.dayParts(day), let date = calendar.date(from: parts) else { return day }
        let weekday = EVText.dayLabels[(calendar.component(.weekday, from: date) + 5) % 7]
        return "\(AppWords.text(weekday)) \(parts.day ?? 1) \(AppWords.text(AppWords.monthLabels[(parts.month ?? 1) - 1]))"
    }

    /// "9–15 Oct", or "28 Sep–4 Oct" across a month's end.
    static func range(_ first: String, _ last: String, calendar: Calendar) -> Phrase {
        guard let a = Savings.dayParts(first), let b = Savings.dayParts(last) else { return Phrase(text: "\(first)–\(last)") }
        let month = { (p: DateComponents) in AppWords.text(AppWords.monthLabels[(p.month ?? 1) - 1]) }
        if a.month == b.month, a.year == b.year {
            return Phrase(text: "\(a.day ?? 1)–\(b.day ?? 1) \(month(b))")
        }
        return Phrase(text: "\(a.day ?? 1) \(month(a))–\(b.day ?? 1) \(month(b))")
    }

    /// "AS OF 14:32", or "SAVED ON THIS PHONE · AS OF TUE 23:10" from the
    /// cache. The day joins the clock when it is not today.
    static func footer(_ answer: Stamped<Savings.Answer>, nowMs: Double, zone: TimeZone) -> String {
        let calendar = EVText.calendar(zone)
        var clock = AppWords.clock(answer.asOfMs, zone: zone)
        if Savings.dayName(answer.asOfMs, calendar: calendar) != Savings.dayName(nowMs, calendar: calendar) {
            let date = Date(timeIntervalSince1970: answer.asOfMs / 1000)
            clock = AppWords.text(EVText.dayLabels[(calendar.component(.weekday, from: date) + 5) % 7]) + " " + clock
        }
        let asOf = NodeWords.format("AS OF %@", clock)
        return (answer.fromCache ? NodeWords.text("SAVED ON THIS PHONE") + " · " + asOf : asOf).uppercased()
    }

    /// The shape of the screen before the box has said anything: the hero
    /// and the lines redacted, the plot empty. Never a bar the box did not
    /// give. A failure says what happens now in their place.
    static func waiting(_ period: Savings.Period, problem: String?, currency: String) -> SavingsGlance {
        let money = SavingsMoney(currency: currency)
        if let problem {
            let reading = Reading(figure: "—", unit: money.unit, word: AppWords.text("Savings"), kicker: nil, known: false, lines: [problem])
            return SavingsGlance(period: period, reading: reading, chart: .empty, footer: " ", placeholder: false)
        }
        let reading = Reading(figure: money.figure(1_840), unit: money.unit, word: AppWords.text("Saved today so far"), kicker: nil, known: false,
                              lines: [AppWords.text("Reading the savings from your box…")])
        return SavingsGlance(period: period, reading: reading, chart: .empty, footer: " ", placeholder: true)
    }

    /// The home node's row: "18,40 kr today", or nil when the box's last
    /// day is not today or has no price.
    public static func row(_ answer: Stamped<Savings.Answer>?, nowMs: Double, currency: String) -> String? {
        guard let a = answer?.value, let last = a.days.last, last.priced else { return nil }
        let calendar = EVText.calendar(EVText.householdZone(boxTZ: a.tz))
        guard last.day == Savings.dayName(nowMs, calendar: calendar) else { return nil }
        let money = SavingsMoney(currency: currency)
        let more = last.savedMinor < 0 && money.figure(last.savedMinor) != money.figure(0)
        return AppWords.format(more ? "cost %@ more today" : "%@ today", money.text(last.savedMinor))
    }
}

/// Minor units as the hero and the lines write them: two decimals under a
/// hundred, none from there, in the language's way, and never a sign. The
/// words say which side of zero.
struct SavingsMoney: Equatable {
    let unit: String

    init(currency: String) {
        unit = GridGlance.currencyUnit(currency)
    }

    /// "18,40", "126"
    func figure(_ minor: Double) -> String {
        let a = abs(minor) / 100
        return AppWords.decimal(PowerFormat.fixed(a, a >= 100 ? 0 : 2))
    }

    /// "18,40 kr"
    func text(_ minor: Double) -> String { figure(minor) + "\u{00A0}" + unit }

    /// The axis: "20 kr", "0,50 kr".
    func axis(_ minor: Double) -> String {
        let a = abs(minor) / 100
        let digits = a >= 1 || a == 0 ? 0 : 2
        return AppWords.decimal(PowerFormat.fixed(a, digits)) + " " + unit
    }
}

// MARK: - The bars

/// A bar per day, as values: the box's saving per day in minor units, the
/// day still filling, the days the box priced only in part, the tag and
/// the hero's reading under a finger, and the labels under the plot.
public struct SavingsChart: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public var index: Int
        public var text: String
        /// Placed first, before the rest that have room.
        public var first: Bool
    }

    /// Saved per day, minor units; nil when the box had no price that day.
    public var values: [Double?]
    /// The day still filling: drawn hatched, on its way.
    public var today: Int?
    public var partial: Set<Int>
    /// The Day view's day, in full ink among the week.
    public var focus: Int?
    public var domain: YDomain
    /// "TUE 14 OCT  18,40 KR"
    public var tags: [String]
    public var labels: [Label]
    public var landmarks: Set<Int>
    /// The top of the scale, "20 kr", and the bottom when a day cost more.
    public var top: String
    public var bottom: String?
    /// The hero and the lines for each day under a finger.
    public var readings: [SavingsGlance.Reading]

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    /// One slot per day, as wide as the plot over the count.
    public var grid: SlotGrid {
        SlotGrid(firstMs: 0, stepMs: 1, count: values.count, fromMs: 0, toMs: Double(max(values.count, 1)))
    }

    static let empty = SavingsChart(values: [], today: nil, partial: [], focus: nil, domain: YDomain(lower: 0, upper: 100), tags: [], labels: [],
                                    landmarks: [], top: "", bottom: nil, readings: [])

    static func make(_ days: [Savings.Figures], focus: Int?, today: String, calendar: Calendar, money: SavingsMoney) -> SavingsChart {
        let values: [Double?] = days.map { $0.priced ? $0.savedMinor : nil }
        let known = values.compactMap { $0 }
        let domain = YDomain.stable(low: known.min() ?? 0, high: known.max() ?? 0, floor: 100)
        let todayIndex = days.lastIndex { $0.day == today }
        var landmarks = Set<Int>()
        if let todayIndex { landmarks.insert(todayIndex) }
        if let hi = known.max(), hi > 0, let i = values.firstIndex(where: { $0 == hi }) { landmarks.insert(i) }
        if let lo = known.min(), lo < 0, let i = values.firstIndex(where: { $0 == lo }) { landmarks.insert(i) }

        let tags = days.map { d -> String in
            let name = d.day == today ? AppWords.text("TODAY") : SavingsGlance.dayText(d.day, calendar: calendar)
            guard d.priced else { return (name + "  " + AppWords.text("NO PRICES")).uppercased() }
            return (name + "  " + money.text(d.savedMinor) + (d.partial ? " · " + AppWords.text("PARTIAL") : "")).uppercased()
        }
        let readings = days.map { d in
            SavingsGlance.reading(d, when: SavingsGlance.when(day: d.day, today: today, calendar: calendar), money: money)
        }

        // A week names each day; a month names the first of each week.
        var labels: [Label] = []
        for (i, d) in days.enumerated() {
            guard let parts = Savings.dayParts(d.day), let date = calendar.date(from: parts) else { continue }
            if d.day == today {
                labels.append(Label(index: i, text: AppWords.text("TODAY"), first: true))
            } else if days.count <= 7 {
                labels.append(Label(index: i, text: AppWords.text(EVText.dayLabels[(calendar.component(.weekday, from: date) + 5) % 7]).uppercased(), first: false))
            } else if ((parts.day ?? 1) - 1) % 7 == 0 {
                labels.append(Label(index: i, text: String(parts.day ?? 1), first: false))
            }
        }
        return SavingsChart(
            values: values,
            today: todayIndex,
            partial: Set(days.indices.filter { days[$0].partial }),
            focus: focus,
            domain: domain,
            tags: tags,
            labels: labels,
            landmarks: landmarks,
            top: money.axis(domain.upper),
            bottom: domain.lower < 0 ? money.axis(domain.lower) : nil,
            readings: readings
        )
    }
}
