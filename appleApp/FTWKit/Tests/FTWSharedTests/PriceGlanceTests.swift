import Foundation
import Testing
@testable import FTWShared

/// The price widgets' timeline, worked out from the cache alone. Times are
/// Stockholm's; 12 October 2026 is a Monday. These read English: the tests
/// run in the development language.
@Suite struct PriceGlanceTests {
    static let hourMs: Double = 3_600_000
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()

    /// Wall clock in Stockholm, as ms.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// Slots back to back from `fromMs`, each `dtMs` long, priced by index.
    func slots(from fromMs: Double, count: Int, dtMs: Double = hourMs, total: (Int) -> Double = { _ in 50 }) -> [PriceSlot] {
        (0..<count).map { i in
            let t = total(i)
            return PriceSlot(startMs: fromMs + Double(i) * dtMs, durationMs: dtMs, spotMinor: t, totalMinor: t)
        }
    }

    func read(_ slots: [PriceSlot], readAtMs: Double, carrier: CarrierKind = .relay, srcState: SourceState = .live) -> CacheRead<PriceEntry> {
        let prices = Prices(zone: "SE3", currency: "SEK", slots: slots, stale: false)
        let record = CacheRecord(siteId: "home", carrier: carrier, srcState: srcState, readAtMs: readAtMs, value: PriceEntry(fromMs: slots.first?.startMs ?? 0, prices: prices))
        return CacheRead(record: record, origin: .app)
    }

    // MARK: The timeline

    @Test func oneMomentNowAndOneAtEveryHourTheBoxPriced() {
        let fetched = at(12, 13, 5)
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: fetched)
        let moments = PriceGlance.moments(r, nowMs: at(12, 13, 30), calendar: calendar)
        #expect(moments.first?.atMs == at(12, 13, 30))
        #expect(moments.count == 1 + 35)
        let steps = zip(moments.dropFirst(), moments.dropFirst(2)).map { $1.atMs - $0.atMs }
        #expect(steps.allSatisfy { $0 == Self.hourMs })
        #expect(moments.last?.atMs == at(14, 0))
    }

    /// Quarter-hour prices give a moment every quarter hour, and a box that
    /// mixes resolutions is followed slot by slot.
    @Test func theTimelineFollowsTheResolutionTheBoxSent() {
        let quarter = Self.hourMs / 4
        let today = slots(from: at(12, 0), count: 24)
        let tomorrow = slots(from: at(13, 0), count: 96, dtMs: quarter)
        let moments = PriceGlance.moments(read(today + tomorrow, readAtMs: at(12, 13, 5)), nowMs: at(12, 22, 30), calendar: calendar)
        let times = moments.map(\.atMs)
        #expect(times.prefix(3) == [at(12, 22, 30), at(12, 23), at(13, 0)])
        #expect(times.contains(at(13, 0, 15)))
        let tail = zip(times.dropFirst(2), times.dropFirst(3)).map { $1 - $0 }
        #expect(tail.allSatisfy { $0 == quarter })
        #expect(moments.last?.state == .ended(lastMs: at(14, 0)))
    }

    @Test func eachMomentShowsTheSlotItFallsIn() {
        let r = read(slots(from: at(12, 0), count: 24) { Double(10 + $0) }, readAtMs: at(12, 6))
        for m in PriceGlance.moments(r, nowMs: at(12, 9, 40), calendar: calendar) where m.state == .price {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: m.atMs / 1000))
            #expect(m.current?.totalMinor == Double(10 + hour))
            #expect(m.priceText == PriceStrip.text(Double(10 + hour), "SEK"))
        }
    }

    // MARK: When the prices run out

    @Test func theLastMomentSaysWhenThePricesRanOut() throws {
        let r = read(slots(from: at(12, 0), count: 18), readAtMs: at(12, 8))
        let last = try #require(PriceGlance.moments(r, nowMs: at(12, 9), calendar: calendar).last)
        #expect(last.atMs == at(12, 18))
        #expect(last.state == .ended(lastMs: at(12, 18)))
        #expect(last.isEmpty)
        #expect(last.priceText == nil)
        #expect(last.cheapestText == nil)
        #expect(last.curve.isEmpty)
        #expect(last.emptyText == "No prices after 18:00 · open FTW")
        #expect(last.inlineText == "No prices · open FTW")
    }

    /// Nothing after the end is priced: not the last hour stretched, not
    /// yesterday's day started over.
    @Test func noMomentAfterTheEndShowsAPrice() {
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: at(12, 13, 5))
        for h in 0..<72 {
            let m = PriceGlance.moment(r, atMs: at(14, 0) + Double(h) * Self.hourMs + 1, calendar: calendar)
            #expect(m.state == .ended(lastMs: at(14, 0)))
            #expect(m.current == nil && m.priceText == nil && m.curve.isEmpty)
        }
    }

    /// The proof case: fetched Monday just after the market published, and
    /// not opened since. Thirty-six hours on, the widget is grey and says
    /// which midnight the prices ended at.
    @Test func thirtySixHoursLaterTheWidgetIsGrey() throws {
        let fetched = at(12, 13, 5)
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: fetched)
        let later = fetched + 36 * Self.hourMs
        let moments = PriceGlance.moments(r, nowMs: later, calendar: calendar)
        #expect(moments.count == 1)
        let m = try #require(moments.first)
        #expect(m.state == .ended(lastMs: at(14, 0)))
        #expect(m.emptyText == "No prices after Tue 24:00 · open FTW")
        #expect(m.fetchedText == "Fetched Mon 13:05")
        #expect(m.carrier == .cache)
    }

    /// An end at midnight is 24:00 of the day it closes, also on the day the
    /// clocks go back and the day has 25 hours.
    @Test func midnightReadsAsTheEndOfTheDayAcrossTheClockChange() throws {
        let day = at(25, 0)
        let next = at(26, 0)
        #expect(next - day == 25 * Self.hourMs)
        let r = read(slots(from: day, count: 25), readAtMs: day)
        let last = try #require(PriceGlance.moments(r, nowMs: at(25, 20), calendar: calendar).last)
        #expect(last.atMs == next)
        #expect(last.emptyText == "No prices after Sun 24:00 · open FTW")
        #expect(PriceGlance.moment(r, atMs: at(25, 22, 30), calendar: calendar).cheapestText == "Cheapest now until 24")
    }

    /// One failed fetch at midday leaves a hole. The widget says so for as
    /// long as it lasts and picks the prices up again after it.
    @Test func aHoleIsSaidNotFilled() {
        let morning = slots(from: at(12, 0), count: 6)
        let afternoon = slots(from: at(12, 12), count: 12)
        let moments = PriceGlance.moments(read(morning + afternoon, readAtMs: at(12, 5)), nowMs: at(12, 5, 30), calendar: calendar)
        let gap = moments.first { $0.atMs == at(12, 6) }
        #expect(gap?.state == .gap(nextMs: at(12, 12)))
        #expect(gap?.emptyText == "No price until 12:00 · open FTW")
        #expect(gap?.priceText == nil)
        #expect(!moments.contains { $0.atMs > at(12, 6) && $0.atMs < at(12, 12) })
        #expect(moments.first { $0.atMs == at(12, 12) }?.state == .price)
    }

    @Test func beforeTheFirstPriceTheWidgetWaitsForIt() {
        let r = read(slots(from: at(12, 6), count: 18), readAtMs: at(12, 5))
        let m = PriceGlance.moment(r, atMs: at(12, 5), calendar: calendar)
        #expect(m.state == .gap(nextMs: at(12, 6)))
        #expect(m.emptyText == "No price until 06:00 · open FTW")
    }

    // MARK: Cheapest next

    /// A day that is dear until midnight and cheapest from 02 to 04.
    func night(dtMs: Double = hourMs, cheapFrom: Double, cheapTo: Double) -> [PriceSlot] {
        let start = at(12, 0)
        let count = Int((at(14, 0) - start) / dtMs)
        return slots(from: start, count: count, dtMs: dtMs) { i in
            let t = start + Double(i) * dtMs
            return t >= cheapFrom && t < cheapTo ? 5 : 80 + Double(i % 7)
        }
    }

    @Test func cheapestNextNamesTheTwoHoursAhead() {
        let r = read(night(cheapFrom: at(13, 2), cheapTo: at(13, 4)), readAtMs: at(12, 13, 5))
        let evening = PriceGlance.moment(r, atMs: at(12, 20), calendar: calendar)
        #expect(evening.cheapest?.startMs == at(13, 2))
        #expect(evening.cheapestText == "Cheapest 02–04")
        // The inline line shares its width with the date: the start alone.
        #expect(evening.inlineText == "\(evening.priceText!) öre · cheapest 02:00")
        // Inside the block it is now, and says until when.
        let inside = PriceGlance.moment(r, atMs: at(13, 2, 30), calendar: calendar)
        #expect(inside.cheapestText == "Cheapest now until 04")
        #expect(inside.cheapestStartText == "cheapest now")
    }

    @Test func cheapestFollowsQuarterHours() {
        let quarter = Self.hourMs / 4
        let r = read(night(dtMs: quarter, cheapFrom: at(13, 2, 15), cheapTo: at(13, 4, 15)), readAtMs: at(12, 13, 5))
        #expect(PriceGlance.moment(r, atMs: at(12, 20), calendar: calendar).cheapestText == "Cheapest 02:15–04:15")
    }

    /// At 14:00, "15–17" would read as this afternoon. Tomorrow's is named.
    @Test func tomorrowIsNamedOnlyWhenTheClockWouldMislead() {
        let r = read(night(cheapFrom: at(13, 15), cheapTo: at(13, 17)), readAtMs: at(12, 13, 5))
        #expect(PriceGlance.moment(r, atMs: at(12, 14), calendar: calendar).cheapestText == "Cheapest tomorrow 15–17")
        #expect(PriceGlance.moment(r, atMs: at(12, 14), calendar: calendar).cheapestStartText == "cheapest tomorrow 15:00")
        // The same block seen the next morning is today's.
        #expect(PriceGlance.moment(r, atMs: at(13, 9), calendar: calendar).cheapestText == "Cheapest 15–17")
    }

    @Test func noCheapestWhenLessThanTwoHoursArePriced() {
        let r = read(slots(from: at(12, 0), count: 24), readAtMs: at(12, 8))
        #expect(PriceGlance.moment(r, atMs: at(12, 23, 30), calendar: calendar).cheapestText == nil)
        #expect(PriceGlance.moment(r, atMs: at(12, 22, 30), calendar: calendar).cheapestText == "Cheapest now until 24")
    }

    @Test func theCurveReachesTwelveHoursAhead() throws {
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: at(12, 13, 5))
        let m = PriceGlance.moment(r, atMs: at(12, 13, 30), calendar: calendar)
        #expect(m.curve.first?.startMs == at(12, 13))
        #expect(m.curve.first?.current == true)
        #expect(m.curve.count == 13)
        #expect(try #require(m.curve.last).startMs < at(12, 13, 30) + PriceGlance.curveMs)
    }

    // MARK: What the total includes

    /// Core's formula, rounded once on the wire as Core rounds it.
    func core(spots: [Double], fee: Double, vat: Double) -> [PriceSlot] {
        spots.enumerated().map { i, spot in
            PriceSlot(startMs: Double(i) * Self.hourMs, durationMs: Self.hourMs, spotMinor: spot.rounded(), totalMinor: ((spot + fee) * (1 + vat / 100)).rounded())
        }
    }

    @Test func theTotalSaysWhatItIncludes() {
        let day = (0..<24).map { 30 + 70 * sin(Double($0) / 4) + Double($0) * 0.37 }
        #expect(PriceGlance.included(core(spots: day, fee: 45, vat: 25)) == .gridFeeAndVAT)
        #expect(PriceGlance.included(core(spots: day, fee: 0, vat: 25)) == .vat)
        #expect(PriceGlance.included(core(spots: day, fee: 45, vat: 0)) == .gridFee)
        #expect(PriceGlance.included(core(spots: day, fee: 0, vat: 0)) == .spotOnly)
        // Cents move little over a day; the line still holds.
        let cents = (0..<96).map { 6 + 4 * sin(Double($0) / 12) }
        #expect(PriceGlance.included(core(spots: cents, fee: 3, vat: 24)) == .gridFeeAndVAT)
        #expect(PriceGlance.included(core(spots: cents, fee: 0, vat: 24)) == .vat)
        // A flat market cannot tell a fee from a percentage.
        #expect(PriceGlance.included(core(spots: Array(repeating: 50, count: 24), fee: 45, vat: 25)) == .surcharges)
        #expect(PriceGlance.text(.gridFeeAndVAT) == "incl. grid fee and VAT")
        #expect(PriceGlance.text(.spotOnly) == "spot price only")
    }

    // MARK: Freshness

    /// A record read back is the cache, whatever carried it and however
    /// healthy the box was then. No moment claims live.
    @Test func aCachedPriceNeverLooksLive() {
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: at(12, 13, 5), carrier: .relay, srcState: .live)
        let moments = PriceGlance.moments(r, nowMs: at(12, 13, 30), calendar: calendar)
        for m in moments {
            #expect(m.carrier == .cache)
            #expect(m.srcState == .live)
            #expect(m.readAtMs == at(12, 13, 5))
            let words = [m.priceText, m.cheapestText, m.emptyText, m.fetchedText, m.includedText, m.inlineText].compactMap { $0 }
            #expect(!words.contains { $0.lowercased().contains("live") })
        }
        #expect(moments.first?.fetchedText == "Fetched 13:05")
        // An answer the box itself called short is kept as such.
        let short = read(slots(from: at(12, 0), count: 24), readAtMs: at(12, 8), srcState: .stale)
        #expect(PriceGlance.moment(short, atMs: at(12, 9), calendar: calendar).srcState == .stale)
    }

    @Test func withNothingCachedTheWidgetAsksForTheApp() {
        let moments = PriceGlance.moments(nil, nowMs: at(12, 9), calendar: calendar)
        #expect(moments.count == 1)
        #expect(moments[0].state == .nothing)
        #expect(moments[0].carrier == .none)
        #expect(moments[0].srcState == .never)
        #expect(moments[0].emptyText == "Open FTW to see prices")
    }

    // MARK: Words

    /// Every sentence a widget shows has a Swedish line with the same
    /// placeholders.
    // MARK: The block strip

    /// Twelve hours from the one that holds now, each the mean of its
    /// slots, as one of eight levels and a third of the range: the small
    /// widget's bars and the lock screen's glyphs.
    @Test func theStripIsTwelveHoursOfBlocks() {
        let quarter = Self.hourMs / 4
        // Quarters: hour h costs 10 × h, so the strip climbs one step a hour.
        let r = read(slots(from: at(12, 0), count: 96, dtMs: quarter) { i in Double(10 * (i / 4)) }, readAtMs: at(12, 13, 5))
        let m = PriceGlance.moment(r, atMs: at(12, 6, 40), calendar: calendar)
        #expect(m.hours.count == 12)
        #expect(m.hours.first?.startMs == at(12, 6))
        #expect(m.hours.first?.current == true)
        #expect(m.hours.dropFirst().allSatisfy { !$0.current })
        #expect(m.hours.map(\.minor) == (6..<18).map { Double(10 * $0) })
        #expect(m.hours.first?.level == 1 && m.hours.last?.level == 8)
        #expect(m.hours.first?.third == .cheap && m.hours.last?.third == .dear)
        #expect(m.glyphs.count == 12)
        #expect(m.glyphs.first == "▁" && m.glyphs.last == "█")
        // Where the market has not priced, the strip ends.
        let late = PriceGlance.moment(r, atMs: at(12, 17), calendar: calendar)
        #expect(late.hours.count == 7)
        #expect(late.glyphs.count == 7)
    }

    /// A flat day is the middle of the scale, not its floor.
    @Test func aFlatDayIsTheMiddleBlock() {
        #expect(PriceBlocks.levels([50, 50, 50]) == [4, 4, 4])
        #expect(PriceBlocks.thirds([50, 50]) == [.middle, .middle])
        #expect(PriceBlocks.levels([0, 100]) == [1, 8])
        #expect(PriceBlocks.levels([-10, 0, 10]) == [1, 5, 8])
    }

    /// Every widget says when the app fetched what it shows.
    @Test func everyMomentSaysAsOf() {
        let r = read(slots(from: at(12, 0), count: 48), readAtMs: at(12, 13, 5))
        #expect(PriceGlance.moment(r, atMs: at(12, 14), calendar: calendar).asOfText == "AS OF 13:05")
        #expect(PriceGlance.moment(r, atMs: at(13, 9), calendar: calendar).asOfText == "AS OF MON 13:05")
        #expect(PriceGlance.moment(nil, atMs: at(12, 14), calendar: calendar).asOfText == nil)
    }

    @Test func everyWidgetWordHasSwedish() throws {
        let url = try #require(Words.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for word in GlanceWord.allCases {
            let sv = try #require(table[word.rawValue], "no Swedish for \"\(word.rawValue)\"")
            #expect(sv.components(separatedBy: "%@").count == word.rawValue.components(separatedBy: "%@").count)
            #expect(sv != word.rawValue)
        }
    }
}
