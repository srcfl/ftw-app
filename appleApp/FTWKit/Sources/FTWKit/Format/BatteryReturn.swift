import Foundation
import FTWShared

/// The figure a Swedish household gives Skatteverket to get back the energy
/// tax on grid electricity that a battery stored and later sent back to the
/// grid (11 kap. 13 § LSE), from `GET /api/energy/battery-return?year=`.
///
/// The box works it out for one calendar year on Swedish time and counts
/// low wherever its readings cannot tell where energy went. The app adds
/// nothing up. It rounds once, down to whole kWh, as the box's own page
/// does, so the figure an owner enters never exceeds what the readings
/// show. A `problem` means no figure at all, with the box's reason.
public enum BatteryReturn {
    /// The first year Skatteverket refunds.
    public static let firstYear = 2018
    /// An owner applies within three years after the year ends.
    public static let yearsToApply = 3
    /// The clock Skatteverket's calendar year runs on.
    public static let zone = TimeZone(identifier: "Europe/Stockholm")!
    /// Skatteverket's own page on the refund.
    public static let rulesURL = URL(string: "https://www.skatteverket.se/privat/skatter/skattpabransleochel/aterbetalningavskattpaelefterbatterilagring.4.5fb2fa71a0b0adb74a23d8.html")!

    /// One calendar month of the year, as the box summed it.
    public struct Month: Codable, Equatable, Sendable {
        /// 1 to 12.
        public var month: Int
        public var returnedWh: Double
        public var hours: Int
        public var completeHours: Int
    }

    /// One battery the box read in the year, with its own account.
    public struct Battery: Codable, Equatable, Sendable {
        /// Its latest identity on the box.
        public var assetId: String
        /// The driver that read it last, as the box's settings name it.
        public var label: String
        /// Whether the box's settings hold its size.
        public var sized: Bool
        public var returnedWh: Double
        /// The least round-trip efficiency its readings allow, 0 to 1.
        public var efficiency: Double
        /// The size the box counted it with.
        public var capacityWh: Double
    }

    /// One year as the box answered it.
    public struct Report: Codable, Equatable, Sendable {
        public var year: Int
        /// What went back from all the batteries, each counted on its own.
        public var returnedWh: Double
        public var hours: Int
        public var completeHours: Int
        public var batteries: [Battery]
        /// The drivers with a battery size that read no battery in the
        /// year.
        public var unread: [String]
        /// Empty when the year has a figure. Any other word is a reason it
        /// has none, one a later box adds included.
        public var problem: String
        public var months: [Month]
    }

    /// The box's answer, or nil when it is not one.
    public static func report(_ wire: JSON?) -> Report? {
        guard let wire, wire.object != nil, let year = wire["year"]?.number, year.isFinite else { return nil }
        func n(_ row: JSON, _ key: String) -> Double { row[key]?.number.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0 }
        let months = (wire["months"]?.array ?? []).enumerated().compactMap { i, row -> Month? in
            let month = row["month"]?.number.map { Int($0) } ?? i + 1
            guard (1...12).contains(month) else { return nil }
            return Month(month: month, returnedWh: n(row, "returned_wh"), hours: Int(n(row, "hours")), completeHours: Int(n(row, "complete_hours")))
        }
        let batteries = (wire["batteries"]?.array ?? []).compactMap { row -> Battery? in
            guard row.object != nil else { return nil }
            return Battery(assetId: row["asset_id"]?.string ?? "", label: row["label"]?.string ?? "", sized: row["sized"]?.bool ?? false,
                           returnedWh: n(row, "returned_wh"), efficiency: n(row, "efficiency"), capacityWh: n(row, "capacity_wh"))
        }
        return Report(
            year: Int(year),
            returnedWh: n(wire, "returned_wh"),
            hours: Int(n(wire, "hours")),
            completeHours: Int(n(wire, "complete_hours")),
            batteries: batteries,
            unread: (wire["unread"]?.array ?? []).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } },
            problem: wire["problem"]?.string ?? "",
            months: months
        )
    }

    /// Whether the refund is the home's: Swedish law, so a price area from
    /// SE1 to SE4.
    public static func applies(zone: String?) -> Bool {
        guard let zone else { return false }
        return ["SE1", "SE2", "SE3", "SE4"].contains(zone.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// The calendar year it is now, on Swedish time.
    public static func thisYear(nowMs: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.component(.year, from: Date(timeIntervalSince1970: nowMs / 1000))
    }

    /// The running year and the ended ones an owner can still apply for,
    /// newest first.
    public static func years(nowMs: Double) -> [Int] {
        let now = thisYear(nowMs: nowMs)
        return Array(stride(from: now, through: max(firstYear, now - yearsToApply), by: -1))
    }

    /// The year an owner applies for: the last one to have ended.
    public static func defaultYear(nowMs: Double) -> Int {
        max(firstYear, thisYear(nowMs: nowMs) - 1)
    }

    /// The figure to enter: whole kWh, rounded down.
    public static func wholeKWh(_ wh: Double) -> Int {
        Int((max(0, wh) / 1000).rounded(.down))
    }

    /// The name of the hourly basis, as the box names the download.
    public static func basisName(_ year: Int) -> String { "ftw-battery-return-\(year).csv" }
}

/// What the refund screen says for one year, built once per answer, year
/// or minute. Every figure is the box's.
public struct BatteryReturnGlance: Equatable, Sendable {
    /// One month of the year.
    public struct Row: Equatable, Sendable, Identifiable {
        public var month: Int
        /// "January"
        public var name: String
        /// "95 kWh", or "No readings".
        public var figure: String
        /// "740 of 744 hours"
        public var hours: String
        public var id: Int { month }
    }

    /// "1 234", or "—" when the year has no figure.
    public var figure: String
    public var unit: String
    /// "Grid electricity stored and sent back in 2025"
    public var word: String
    /// The hours behind the figure and the batteries it was counted with,
    /// or why there is no figure.
    public var lines: [String]
    public var months: [Row]
    /// `AS OF 14:32`, or a space while nothing is dated.
    public var footer: String
    /// Nothing from the box yet: the shape of the screen, redacted.
    public var placeholder: Bool
    /// Whether the hourly basis behind a figure can be shared.
    public var hasBasis: Bool

    public static func make(year: Int, answer: Stamped<BatteryReturn.Report>?, problem: String?, nowMs: Double) -> BatteryReturnGlance {
        let running = year == BatteryReturn.thisYear(nowMs: nowMs)
        guard let answer, answer.value.year == year else { return waiting(year, problem: problem) }
        let r = answer.value
        let footer = Self.footer(answer, nowMs: nowMs)
        let months = r.months.filter { $0.hours > 0 }.map(row)
        let unit = "kWh"
        let words = BatteryReturnWords.self
        if !r.problem.isEmpty {
            // No figure for the year is no figure for its months either:
            // the box's zeros there are not what went back.
            return BatteryReturnGlance(figure: "—", unit: unit, word: words.format("No figure for %@", String(year)),
                                       lines: [reason(r)], months: [], footer: footer, placeholder: false, hasBasis: false)
        }
        guard r.completeHours > 0 else {
            return BatteryReturnGlance(figure: "—", unit: unit, word: words.format("No figure for %@", String(year)),
                                       lines: [words.format("FTW has no complete readings for %@.", String(year))],
                                       months: months, footer: footer, placeholder: false, hasBasis: false)
        }
        var hours = words.format("Complete readings for %1$@ of %2$@ hours.", whole(r.completeHours), whole(r.hours))
        if running { hours += " " + words.text("The year is still running.") }
        return BatteryReturnGlance(
            figure: whole(BatteryReturn.wholeKWh(r.returnedWh)),
            unit: unit,
            word: words.format(running ? "Grid electricity stored and sent back in %@ so far" : "Grid electricity stored and sent back in %@", String(year)),
            lines: [hours] + counted(r.batteries),
            months: months,
            footer: footer,
            placeholder: false,
            hasBasis: true
        )
    }

    /// How the figure was counted: the battery's size and the least it
    /// gives back, or, with several, a line for each and what came from it.
    static func counted(_ batteries: [BatteryReturn.Battery]) -> [String] {
        let words = BatteryReturnWords.self
        func percent(_ efficiency: Double) -> String { "\(Int((efficiency * 100).rounded(.down)))\u{00A0}%" }
        if batteries.count == 1, let b = batteries.first {
            return [words.format("Counted with a %1$@ battery that gives back at least %2$@ of its charge.", kWh(b.capacityWh), percent(b.efficiency))]
        }
        guard !batteries.isEmpty else { return [] }
        return [words.text("Counted for each battery on its own:")] + batteries.enumerated().map { i, b in
            let name = b.label.isEmpty ? words.format("battery %@", String(i + 1)) : quoted(b.label)
            return words.format("%1$@ from %2$@, a %3$@ battery that gives back at least %4$@ of its charge.",
                                "\(whole(BatteryReturn.wholeKWh(b.returnedWh)))\u{00A0}kWh", name, kWh(b.capacityWh), percent(b.efficiency))
        }
    }

    /// Why a year has no figure, from the box's battery settings.
    static func reason(_ r: BatteryReturn.Report) -> String {
        let words = BatteryReturnWords.self
        switch r.problem {
        case "battery_size":
            var seen = Set<String>()
            let names = r.batteries.filter { !$0.sized && !$0.label.isEmpty && seen.insert($0.label).inserted }.map { quoted($0.label) }
            if names.isEmpty {
                return words.text("Set the battery's size on your box's own page to get a figure. FTW needs to know how much it holds.")
            }
            return words.format("Set the battery size for %@ on your box's own page to get a figure. FTW needs to know how much each battery holds.", list(names))
        case "battery_unread" where !r.unread.isEmpty:
            return words.format("Your box has a battery size for %1$@ but read no battery there in %2$@. FTW could then count what one battery sent to the grid as another's, so there is no figure.",
                                list(r.unread.map(quoted)), String(r.year))
        default:
            return words.format("Your box gives no figure for %@.", String(r.year))
        }
    }

    /// A driver's name as the box's settings write it, in the language's
    /// quotes.
    static func quoted(_ name: String) -> String {
        AppWords.language == .sv ? "\u{201D}\(name)\u{201D}" : "\u{201C}\(name)\u{201D}"
    }

    /// "a", "a and b", "a, b and c", in the words' language.
    static func list(_ items: [String]) -> String {
        let f = ListFormatter()
        f.locale = BatteryReturnWords.locale
        return f.string(from: items) ?? items.joined(separator: ", ")
    }

    static func row(_ m: BatteryReturn.Month) -> Row {
        let words = BatteryReturnWords.self
        return Row(
            month: m.month,
            name: monthName(m.month),
            figure: m.completeHours > 0 ? "\(whole(BatteryReturn.wholeKWh(m.returnedWh)))\u{00A0}kWh" : words.text("No readings"),
            hours: words.format("%1$@ of %2$@ hours", whole(m.completeHours), whole(m.hours))
        )
    }

    /// The shape of the screen before the box has said anything for the
    /// year. A failure says what happens now in its place.
    static func waiting(_ year: Int, problem: String?) -> BatteryReturnGlance {
        let words = BatteryReturnWords.self
        if let problem {
            return BatteryReturnGlance(figure: "—", unit: "kWh", word: words.format("No figure for %@", String(year)),
                                       lines: [problem], months: [], footer: " ", placeholder: false, hasBasis: false)
        }
        return BatteryReturnGlance(figure: whole(1_234), unit: "kWh",
                                   word: words.format("Grid electricity stored and sent back in %@", String(year)),
                                   lines: [words.format("Working out %@…", String(year))], months: [], footer: " ", placeholder: true, hasBasis: false)
    }

    /// When the box worked the figure out, and whether this phone kept it.
    static func footer(_ answer: Stamped<BatteryReturn.Report>, nowMs: Double) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BatteryReturn.zone
        let sameDay = calendar.isDate(Date(timeIntervalSince1970: answer.asOfMs / 1000), inSameDayAs: Date(timeIntervalSince1970: nowMs / 1000))
        let at = sameDay ? AppWords.clock(answer.asOfMs, zone: BatteryReturn.zone) : AppWords.day(answer.asOfMs, nowMs: nowMs, zone: BatteryReturn.zone)
        let asOf = NodeWords.format("AS OF %@", at)
        return (answer.fromCache ? NodeWords.text("SAVED ON THIS PHONE") + " · " + asOf : asOf).uppercased()
    }

    /// "1 234" in English, "1 234" with a no-break space in Swedish.
    static func whole(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = BatteryReturnWords.locale
        return f.string(from: n as NSNumber) ?? String(n)
    }

    /// "13.5 kWh", one decimal where it has one.
    static func kWh(_ wh: Double) -> String {
        let kwh = (max(0, wh) / 100).rounded() / 10
        let text = kwh == kwh.rounded() ? String(Int(kwh)) : PowerFormat.fixed(kwh, 1)
        return "\(AppWords.decimal(text))\u{00A0}kWh"
    }

    /// "January", in the language the words speak.
    static func monthName(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = BatteryReturnWords.locale
        let name = calendar.standaloneMonthSymbols[(month + 11) % 12]
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// The refund's words, in English or Swedish as `AppWords` speaks. Keyed by
/// the English, so a missing entry shows English; a test reads the screen
/// and fails on any sentence without Swedish.
public enum BatteryReturnWords {
    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? AppWords.text(en)) : en
    }

    /// `%@` in order, or `%1$@` by position, replaced with ready text.
    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    /// The names the system spells, such as months, in the same language.
    static var locale: Locale { Locale(identifier: AppWords.language == .sv ? "sv_SE" : "en_GB") }

    static let sv: [String: String] = [
        "Energy tax refund": "Energiskatt tillbaka",
        "The figure for Skatteverket after battery storage": "Siffran till Skatteverket efter batterilagring",
        "Grid electricity stored and sent back in %@": "Nätel som lagrats och skickats tillbaka %@",
        "Grid electricity stored and sent back in %@ so far": "Nätel som lagrats och skickats tillbaka hittills %@",
        "No figure for %@": "Ingen siffra för %@",
        "Working out %@…": "Räknar ut %@…",
        "Complete readings for %1$@ of %2$@ hours.": "Fullständiga mätvärden för %1$@ av %2$@ timmar.",
        "The year is still running.": "Året pågår fortfarande.",
        "Counted with a %1$@ battery that gives back at least %2$@ of its charge.": "Räknat med ett batteri på %1$@ som ger tillbaka minst %2$@ av sin laddning.",
        "Counted for each battery on its own:": "Räknat för varje batteri för sig:",
        "%1$@ from %2$@, a %3$@ battery that gives back at least %4$@ of its charge.": "%1$@ från %2$@, ett batteri på %3$@ som ger tillbaka minst %4$@ av sin laddning.",
        "battery %@": "batteri %@",
        "FTW has no complete readings for %@.": "FTW har inga fullständiga mätvärden för %@.",
        "Set the battery's size on your box's own page to get a figure. FTW needs to know how much it holds.": "Ange batteriets storlek på boxens egen sida för att få en siffra. FTW behöver veta hur mycket det rymmer.",
        "Set the battery size for %@ on your box's own page to get a figure. FTW needs to know how much each battery holds.": "Ange batteristorleken för %@ på boxens egen sida för att få en siffra. FTW behöver veta hur mycket varje batteri rymmer.",
        "Your box has a battery size for %1$@ but read no battery there in %2$@. FTW could then count what one battery sent to the grid as another's, so there is no figure.": "Boxen har en batteristorlek för %1$@ men läste inget batteri där under %2$@. Då kunde FTW räkna det ett batteri skickade till nätet som ett annat batteris, så det blir ingen siffra.",
        "Your box gives no figure for %@.": "Boxen ger ingen siffra för %@.",
        "No readings": "Inga mätvärden",
        "%1$@ of %2$@ hours": "%1$@ av %2$@ timmar",
        "Year": "År",
        "%@ so far": "%@ hittills",
        "By month": "Per månad",
        "Hourly basis (CSV)": "Timunderlag (CSV)",
        "Keep it with your application.": "Spara det med din ansökan.",
        "Where the readings can't tell where energy went, FTW counts low. The figure assumes FTW reads every solar inverter, battery and charger in the home.": "Där mätvärdena inte visar vart energin tog vägen räknar FTW lågt. Siffran förutsätter att FTW läser alla solväxelriktare, batterier och laddare i hemmet.",
        "You can apply up to three years after the year ends, and your box keeps the hourly readings that long.": "Du kan ansöka upp till tre år efter årets slut, och boxen sparar timvärdena så länge.",
        "Skatteverket's rules": "Skatteverkets regler",
        "Opens the figure for Skatteverket.": "Öppnar siffran till Skatteverket.",
    ]
}
