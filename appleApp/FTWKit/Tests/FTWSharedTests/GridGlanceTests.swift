import Foundation
import Testing
@testable import FTWShared
#if canImport(AppKit)
import AppKit
#endif

/// The grid widget, worked out from a `GridTodayEntry` alone. Times are
/// Stockholm's; 13 October 2026 is a Tuesday, and summer time ends on 25
/// October.
@Suite struct GridGlanceTests {
    static let quarter: Double = 900_000
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// A day that sold more than it bought: 400 W bought through the night,
    /// a hole from 10:00 to 10:30, 3 kW sold around noon, bought again from
    /// 16:00. Read at 16:55.
    func entry(importWh: Double = 6_500, exportWh: Double = 8_300, costMinor: Double? = -420, coverage: Double = 1) -> GridTodayEntry {
        let start = at(13, 0)
        let quarters = (0..<68).map { i -> GridTodayEntry.Quarter in
            let t = start + Double(i) * Self.quarter
            switch i {
            case 40..<42: return .init(startMs: t, importW: nil, exportW: nil)
            case 44..<60: return .init(startMs: t, importW: 0, exportW: i == 52 ? 3_000 : 1_500)
            case 60...: return .init(startMs: t, importW: 900, exportW: 0)
            default: return .init(startMs: t, importW: 400, exportW: 0)
            }
        }
        return GridTodayEntry(day: "2026-10-13", dayStartMs: start, dayEndMs: at(14, 0), importWh: importWh, exportWh: exportWh, costMinor: costMinor,
                              pricedCoverage: coverage, currency: "SEK", timeZone: "Europe/Stockholm", quarters: quarters)
    }

    func read(_ e: GridTodayEntry, readAtMs: Double) -> CacheRead<GridTodayEntry> {
        CacheRead(record: CacheRecord(siteId: "home", carrier: .relay, srcState: .live, readAtMs: readAtMs, value: e), origin: .app)
    }

    func moment(_ e: GridTodayEntry, readAtMs: Double? = nil, at t: Double? = nil, _ language: GridLanguage) -> GridGlance.Moment {
        let read = read(e, readAtMs: readAtMs ?? at(13, 16, 55))
        return GridGlance.moment(read, atMs: t ?? at(13, 17), calendar: calendar, language: language)
    }

    // MARK: Figures

    @Test func swedishTakesACommaAndEnglishAPoint() {
        let sv = moment(entry(), .sv)
        #expect(sv.state == .today)
        #expect(sv.netText == "1,8")
        #expect(sv.unit == "kWh")
        #expect(sv.inOutText == "in 6,5 · ut 8,3 kWh")
        #expect(sv.timeText == "kl 16:55")

        let en = moment(entry(), .en)
        #expect(en.netText == "1.8")
        #expect(en.inOutText == "in 6.5 · out 8.3 kWh")
        #expect(en.timeText == "at 16:55")

        // One decimal however large: the line never changes its shape.
        let big = moment(entry(importWh: 14_000, exportWh: 2_000), .sv)
        #expect(big.netText == "12,0")
        #expect(big.inOutText == "in 14,0 · ut 2,0 kWh")
    }

    /// Net is a magnitude with a word, never a signed figure: bought when
    /// the home took more than it gave, sold when it gave more.
    @Test func theWordSaysWhichWayAndTheFigureNeverCarriesASign() {
        let selling = moment(entry(importWh: 6_500, exportWh: 8_300), .sv)
        #expect(selling.direction == .toGrid)
        #expect(selling.netWord == "sålt netto")

        let buying = moment(entry(importWh: 8_300, exportWh: 6_500, costMinor: 1_240), .sv)
        #expect(buying.direction == .fromGrid)
        #expect(buying.netWord == "köpt netto")
        #expect(buying.netText == "1,8")
        #expect(moment(entry(importWh: 8_300, exportWh: 6_500), .en).netWord == "bought, net")

        // Even to the tenth.
        let even = moment(entry(importWh: 5_000, exportWh: 5_040), .en)
        #expect(even.direction == .even)
        #expect(even.netWord == "even, net")
        #expect(even.netText == "0.0")

        for m in [selling, buying, even] {
            #expect(!(m.netText ?? "").contains("-") && !(m.netText ?? "").contains("−"))
            // Both sides are always there beside the net.
            #expect(m.inOutText != nil)
        }
        #expect(GridGlance.upWord(.sv) == "↑ KÖPER")
        #expect(GridGlance.downWord(.en) == "↓ SELLING")
    }

    /// The box's `actual_cost_ore / 100`. Money earned carries a minus sign,
    /// a real one, and is marked as earned so the view can colour it.
    @Test func aDayThatEarnedShowsAMinusAndSaysSo() {
        let earned = moment(entry(costMinor: -420), .sv)
        #expect(earned.costText == "−4,20")
        #expect(earned.costUnit == "kr")
        #expect(earned.earned)
        #expect(moment(entry(costMinor: -420), .en).costText == "−4.20")

        let paid = moment(entry(costMinor: 1_240), .sv)
        #expect(paid.costText == "12,40")
        #expect(!paid.earned)

        // Two decimals under a hundred kronor, none from there.
        #expect(moment(entry(costMinor: 12_345), .sv).costText == "123")
        #expect(moment(entry(costMinor: -12_345), .en).costText == "−123")
        // A minus on a figure that rounds to nothing would claim money that
        // was not earned.
        let nothing = moment(entry(costMinor: -0.4), .sv)
        #expect(nothing.costText == "0,00")
        #expect(!nothing.earned)
        #expect(GridGlance.currencyUnit("EUR") == "€")
        #expect(GridGlance.currencyUnit("PLN") == "PLN")
    }

    @Test func voiceOverHearsTheDirectionInWords() {
        let en = moment(entry(), .en)
        #expect(en.spoken == "1.8 kWh net to the grid today. in 6.5 · out 8.3 kWh. earned 4.20 kr. at 16:55")
        let sv = moment(entry(importWh: 8_300, exportWh: 6_500, costMinor: 1_240, coverage: 0.5), .sv)
        #expect(sv.spoken == "1,8 kWh netto från nätet i dag. in 8,3 · ut 6,5 kWh. kostnad 12,40 kr. delvis. kl 16:55")
    }

    // MARK: The cost's mark

    @Test func aCostTheBoxCouldNotFullyPriceIsMarkedPartial() {
        let partial = moment(entry(coverage: 0.94), .sv)
        #expect(partial.partial)
        #expect(partial.costNote == "delvis")
        #expect(moment(entry(coverage: 0.94), .en).costNote == "partial")

        let whole = moment(entry(coverage: 0.95), .sv)
        #expect(!whole.partial)
        #expect(whole.costNote == nil)

        // No prices at all: no cost, said in words, not a zero.
        let none = moment(entry(costMinor: nil, coverage: 0), .sv)
        #expect(none.costText == nil)
        #expect(!none.partial)
        #expect(none.costNote == "inga priser")
        #expect(moment(entry(costMinor: nil, coverage: 0), .en).costNote == "no prices")
    }

    // MARK: The day boundary

    /// After local midnight yesterday's figures are not today's: the
    /// widget goes grey and says so until the app has read the new day.
    @Test func afterMidnightYesterdayIsNotShownAsToday() {
        let late = read(entry(), readAtMs: at(13, 23, 55))
        let moments = GridGlance.moments(late, nowMs: at(13, 23, 58), calendar: calendar, language: .sv)
        #expect(moments.count == 2)
        #expect(moments[0].state == .today)
        #expect(moments[0].netText == "1,8")
        #expect(moments[1].atMs == at(14, 0))
        #expect(moments[1].state == .newDay)
        #expect(moments[1].isGrey)
        #expect(moments[1].netText == nil)
        #expect(moments[1].costText == nil)
        #expect(!moments[1].hasChart)
        #expect(moments[1].emptyText == "Dagens siffror har inte kommit än · öppna FTW")
        #expect(moments[1].timeText == "senast tis 23:55")
        // The new day's axis, not yesterday's.
        #expect(moments[1].dayStartMs == at(14, 0))

        let en = GridGlance.moment(late, atMs: at(14, 0, 1), calendar: calendar, language: .en)
        #expect(en.emptyText == "Today's figures aren't here yet · open FTW")
        #expect(en.timeText == "last Tue 23:55")

        // Read after midnight, the new day's record is today's again.
        var fresh = entry()
        fresh.day = "2026-10-14"
        let next = GridGlance.moment(read(fresh, readAtMs: at(14, 0, 10)), atMs: at(14, 0, 15), calendar: calendar, language: .sv)
        #expect(next.state == .today)
        #expect(next.timeText == "kl 00:10")
    }

    @Test func nothingLeftSendsTheReaderToTheApp() {
        let moments = GridGlance.moments(nil, nowMs: at(13, 12), calendar: calendar, language: .sv)
        #expect(moments.count == 1)
        #expect(moments[0].state == .nothing)
        #expect(moments[0].emptyText == "Öppna FTW för att se nätet i dag")
        #expect(moments[0].timeText == nil)
    }

    /// The day the clocks go back has 25 hours; the axis still runs from
    /// midnight to midnight, with noon at 12.
    @Test func theAxisRunsMidnightToMidnightOnTheHouseholdsClock() throws {
        let day = try #require(GridTodayEntry.bounds(day: "2026-10-25", calendar: calendar))
        #expect(day.endMs - day.startMs == 25 * 3_600_000)
        let ticks = GridGlance.xTicks(dayStartMs: day.startMs, dayEndMs: day.endMs, calendar: calendar)
        #expect(ticks.map(\.label) == ["00", "06", "12", "18", "24"])
        #expect(ticks[2].value == at(25, 12))
        #expect(ticks[2].value - day.startMs == 13 * 3_600_000)
        #expect(ticks[4].value == day.endMs)
        #expect(GridTodayEntry.dayName(at(25, 23, 30), calendar: calendar) == "2026-10-25")
        #expect(GridTodayEntry.bounds(day: "yesterday", calendar: calendar) == nil)
    }

    // MARK: The chart

    /// Subpaths in a path: one per run of data.
    func runs(_ p: ChartPath) -> Int {
        p.elements.filter { if case .move = $0 { return true } else { return false } }.count
    }

    /// One signed line, as the app draws the grid's Today: each quarter's
    /// net power, bought above zero and sold below, in slots of 30 minutes
    /// on the medium widget and 60 on the small one. The hole from 10:00
    /// breaks it, and nothing is drawn after the read.
    @Test func theDayIsOneSignedLineThatBreaksAtAHole() {
        let m = moment(entry(), .sv)
        #expect(m.samples.count == 68)
        #expect(m.samples[0].value == 400)
        #expect(m.samples[40].value == nil && m.samples[41].value == nil)
        #expect(m.samples[52].value == -3_000)
        #expect(m.samples[60].value == 900)
        #expect(m.hasChart)

        let medium = m.series(size: CGSize(width: 300, height: 80))
        #expect(medium.grid.stepMs == 1_800_000)
        #expect(medium.grid.count == 48)
        #expect(runs(medium.line) == 2)
        #expect(medium.missing.map(\.lowerBound) == [20])
        // Buying above zero, selling below, on a scale with room for both.
        #expect(medium.domain.upper >= GridGlance.floorW)
        #expect(medium.domain.lower <= -3_000)
        #expect(medium.points[1]!.y < YMap(domain: medium.domain, height: 80).baseline)
        #expect(medium.points[26]!.y > YMap(domain: medium.domain, height: 80).baseline)
        // Nothing after 16:55: the slot from 17:00 on has not happened, and
        // it is not a hole.
        #expect(medium.points[34] == nil)
        #expect(medium.lastData == 33)
        #expect(!medium.missing.contains { $0.contains(34) })

        let small = m.series(size: CGSize(width: 130, height: 50))
        #expect(small.grid.stepMs == 3_600_000)
        #expect(small.grid.count == 24)
        #expect(m.xTicks.map(\.label) == ["00", "06", "12", "18", "24"])
    }

    /// A hole while selling breaks the line in two; neither run lands on
    /// zero to close the gap.
    @Test func aHoleWhileSellingBreaksTheLine() {
        var e = entry()
        // The box lost the meter at 12:00 for half an hour.
        for i in e.quarters.indices where e.quarters[i].startMs >= at(13, 12) && e.quarters[i].startMs < at(13, 12, 30) {
            e.quarters[i] = .init(startMs: e.quarters[i].startMs, importW: nil, exportW: nil)
        }
        let series = moment(e, .sv).series(size: CGSize(width: 300, height: 80))
        #expect(runs(series.line) == 3)
        #expect(series.missing.map(\.lowerBound) == [20, 24])
        #expect(series.points[23]!.y > YMap(domain: series.domain, height: 80).baseline)
        #expect(series.points[25]!.y > YMap(domain: series.domain, height: 80).baseline)
    }

    /// A quarter that bought some and sold some is drawn as its net.
    @Test func aQuarterThatBoughtAndSoldIsItsNet() {
        var e = entry()
        e.quarters[10] = .init(startMs: e.quarters[10].startMs, importW: 1_200, exportW: 300)
        #expect(moment(e, .en).samples[10].value == 900)
    }

    /// A day that only bought has nothing under zero: the scale ends there.
    @Test func aDayThatOnlyBoughtHasNoLowerSide() {
        var e = entry()
        e.quarters = e.quarters.map { .init(startMs: $0.startMs, importW: $0.importW.map { max($0, 2_300) }, exportW: $0.exportW.map { _ in 0 }) }
        let series = moment(e, .en).series(size: CGSize(width: 300, height: 80))
        #expect(series.domain.lower == 0)
        #expect(series.domain.upper >= 2_300)
        // A quiet day keeps the floor, so its noise stays small.
        var quiet = entry()
        quiet.quarters = quiet.quarters.map { .init(startMs: $0.startMs, importW: $0.importW.map { _ in 60 }, exportW: $0.exportW.map { _ in 0 }) }
        #expect(moment(quiet, .en).series(size: CGSize(width: 300, height: 80)).domain.upper == GridGlance.floorW)
    }

    // MARK: Quarters from history

    /// Five-minute steps into quarter hours: a mean over what the box has,
    /// a hole only where it has nothing, and nothing after the read.
    @Test func quartersAreMeansOfWhatTheBoxRecorded() {
        let start = at(13, 0)
        let five: Double = 300_000
        func step(_ i: Int, _ w: Double?) -> (startMs: Double, stepMs: Double, watts: Double?) { (start + Double(i) * five, five, w) }
        let steps = [step(0, 400), step(1, 400), step(2, nil),
                     step(3, nil), step(4, nil), step(5, nil),
                     step(6, 600), step(7, -300), step(8, 0),
                     step(9, -1_200), step(10, 5_000), step(11, 5_000)]
        // Read at 00:50: the fourth quarter is under way.
        let q = GridTodayEntry.quarters(steps, dayStartMs: start, untilMs: start + 10 * five)
        #expect(q.count == 4)
        #expect(q[0] == .init(startMs: start, importW: 400, exportW: 0))
        #expect(q[1] == .init(startMs: start + Self.quarter, importW: nil, exportW: nil))
        #expect(!q[1].measured)
        #expect(q[2] == .init(startMs: start + 2 * Self.quarter, importW: 200, exportW: 100))
        // Only the step that began before the read counts.
        #expect(q[3] == .init(startMs: start + 3 * Self.quarter, importW: 0, exportW: 1_200))

        // An hourly step covers four quarters, and a step before midnight
        // none.
        let hourly = GridTodayEntry.quarters([(start - 3_600_000, 3_600_000, 9_999), (start, 3_600_000, 800)], dayStartMs: start, untilMs: start + 3_600_000)
        #expect(hourly.count == 4)
        #expect(hourly.allSatisfy { $0.importW == 800 })
        #expect(GridTodayEntry.quarters(steps, dayStartMs: start, untilMs: start).isEmpty)
    }

    // MARK: The record

    @Test func theSnapshotComesBackAsItWasWrittenAndAsTheCache() throws {
        let files = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-grid-\(UUID().uuidString)"))
        let e = entry(costMinor: nil, coverage: 0.4)
        try files.write(CacheRecord(siteId: "home", carrier: .relay, srcState: .lagging, readAtMs: at(13, 16, 55), value: e))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path) == ["grid-today-home"])
        let reader = CacheReader(sources: [files])
        #expect(reader.latestSiteID(GridTodayEntry.self) == "home")
        let back = try #require(reader.read(GridTodayEntry.self, siteId: "home"))
        #expect(back.value == e)
        // The hole and the missing cost survive the trip as holes.
        #expect(back.value.quarters[40].importW == nil)
        #expect(back.value.costMinor == nil)
        #expect(back.record.carrier == .relay)
        #expect(back.carrier == .cache)
        #expect(back.srcState == .lagging)
        #expect(back.record.readAtMs == at(13, 16, 55))
        // Not one of the other records.
        #expect(files.read(PlanEntry.self, siteId: "home") == nil)
    }

    // MARK: Words and symbols

    @Test func everyWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Grid", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in GridWord.allCases {
            let swedish = try #require(sv[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(swedish != word.rawValue)
            #expect(word.rawValue.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(word.rawValue)")
        }
        #expect(GridGlance.title(.sv) == "Nätet i dag")
        #expect(GridGlance.title(.en) == "Grid today")
    }

    #if canImport(AppKit)
    /// The symbols the widget draws exist. macOS shares iOS's names for
    /// these; the iOS 26 runtime lists them in `name_availability.plist`.
    @Test func theSymbolsExist() {
        for name in [GridGlance.symbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
    #endif
}
