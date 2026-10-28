import CoreGraphics
import Foundation
import Testing
@testable import FTWShared

/// History's price row, the window a day's prices are drawn in, and the
/// finger that moves a chart through time. In English unless a test says
/// otherwise.
@Suite struct PriceDayTests {
    static let stockholm = ZoneClock.of(TimeZone(identifier: "Europe/Stockholm")!)

    static func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        stockholm.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    /// Quarter hours across one day, as the Nordic market has priced since
    /// October 2025. `total` is what the household pays.
    static func quarters(_ day: Int, hours: Range<Int> = 0..<24, total: (Int) -> Double) -> [PriceSlot] {
        hours.flatMap { hour in
            (0..<4).map { q in
                PriceSlot(startMs: local(day, hour) + Double(q) * 900_000, durationMs: 900_000,
                          spotMinor: total(hour) * 0.6, totalMinor: total(hour))
            }
        }
    }

    static func day(_ slots: [PriceSlot], _ day: Int = 20) -> PriceDay {
        PriceDay.make(slots, fromMs: local(day, 0), toMs: local(day + 1, 0), currency: "SEK", clock: stockholm)
    }

    @Test func aWholeDayAveragesByHowLongEachPriceHeld() {
        // 50 öre until 06, 150 after it: a quarter of the day cheap.
        let d = Self.day(Self.quarters(20) { $0 < 6 ? 50 : 150 })
        #expect(d.known)
        #expect(d.meanMinor == 125)
        #expect(d.lowMinor == 50)
        #expect(d.lowAtMs == Self.local(20, 0))
        #expect(d.highMinor == 150)
        #expect(d.covered == 1)
        #expect(d.note == nil)
        #expect(d.bars.count == 96)
        // The whole day, midnight to midnight, each quarter a 96th of it.
        #expect(abs(d.bars[0].at) < 1e-9)
        #expect(abs(d.bars[0].width - 1 / 96) < 1e-9)
        #expect(abs((d.bars.last!.at + d.bars.last!.width) - 1) < 1e-9)
        // Ink by the day's own thirds: 50 is cheap, 150 dear.
        #expect(d.bars[0].third == .cheap)
        #expect(d.bars.last?.third == .dear)
    }

    /// The Swedish of every price word is checked in `ChartRecipeTests`;
    /// the figures here take the running language's decimal mark.
    @Test func theWordsGiveTheAverageAndTheCheapestSlotWithItsTime() throws {
        let d = Self.day(Self.quarters(20) { $0 == 3 ? 11 : 100 })
        #expect(d.line == "Average \(Words.decimal("96.3")) öre · lowest \(Words.decimal("11.0")) at 03:00")
        let url = try #require(Words.bundle.url(forResource: "Price", withExtension: "strings", subdirectory: nil, localization: "sv"))
        let sv = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(sv["Average %@ · lowest %@ at %@"] == "Snitt %@ · lägst %@ kl %@")
        #expect(sv["%@ with no price"] == "%@ utan pris")
    }

    /// A day the box only partly fetched. The hours it has no price for
    /// weigh nothing in the average, draw no bar, and are said in words —
    /// a hole is never a day that cost nothing.
    @Test func holesAreHolesAndNeverZero() {
        let d = Self.day(Self.quarters(20, hours: 0..<6) { _ in 40 } + Self.quarters(20, hours: 12..<24) { _ in 100 })
        #expect(d.meanMinor == 80)
        #expect(d.bars.count == 72)
        // Nothing is drawn between 06:00 and 12:00.
        #expect(!d.bars.contains { $0.at > 6.0 / 24 && $0.at < 11.9 / 24 })
        #expect(abs(d.covered - 0.75) < 1e-9)
        #expect(d.note == "6 h with no price")
    }

    @Test func aDayTheBoxHasNoPriceForSaysSo() {
        let d = Self.day([])
        #expect(!d.known)
        #expect(d.meanMinor == nil)
        #expect(d.bars.isEmpty)
        #expect(d.line == "No prices for this day")
        #expect(d.note == nil)
        #expect(d.covered == 0)
        // Before the box has said anything the row holds this shape, and
        // the view redacts it.
        #expect(PriceDay.shape(currency: "SEK") == "Average 0 öre · lowest 0 at 00:00")
    }

    @Test func aSlotAcrossMidnightWeighsOnlyThePartInsideTheDay() {
        // One hour slot from 23:30 the day before, and one from 23:30 this
        // day: each gives the day half an hour.
        let slots = [
            PriceSlot(startMs: Self.local(19, 23, 30), durationMs: 3_600_000, spotMinor: 0, totalMinor: 0),
            PriceSlot(startMs: Self.local(20, 0, 30), durationMs: 23 * 3_600_000, spotMinor: 60, totalMinor: 100),
            PriceSlot(startMs: Self.local(20, 23, 30), durationMs: 3_600_000, spotMinor: 120, totalMinor: 200),
        ]
        let d = Self.day(slots)
        // 0.5 h at 0, 23 h at 100, 0.5 h at 200: the ends cancel.
        #expect(d.meanMinor == 100)
        #expect(d.covered == 1)
        #expect(abs(d.bars[0].width - 0.5 / 24) < 1e-9)
        #expect(abs((d.bars.last!.at + d.bars.last!.width) - 1) < 1e-9)
    }

    /// The figures carry no minus sign, as nothing in the app does, so the
    /// words beside them say the market went below zero. Without that,
    /// "lowest 13,0" reads as a cost — and the row hands the same string
    /// to VoiceOver.
    @Test func belowZeroIsSaidInWordsBesideTheUnsignedFigures() {
        let d = Self.day(Self.quarters(20) { $0 == 2 ? -13 : 90 })
        #expect(d.lowMinor == -13)
        #expect(d.bars.first(where: { $0.minor < 0 })?.third == .cheap)
        #expect(d.line == "Average \(Words.decimal("85.7")) öre · lowest \(Words.decimal("13.0")) at 02:00")
        #expect(d.note == "Below zero: you are paid to use power")

        // A whole day below zero says it too, from the average alone.
        let paid = Self.day(Self.quarters(20) { _ in -4 })
        #expect(paid.note == "Below zero: you are paid to use power")
        // A day that never went below zero says nothing.
        #expect(Self.day(Self.quarters(20) { _ in 90 }).note == nil)
        // Both at once, in one line.
        let both = Self.day(Self.quarters(20, hours: 0..<12) { $0 == 2 ? -13 : 90 })
        #expect(both.note == "Below zero: you are paid to use power · 12 h with no price")
    }

    // MARK: The window a day is drawn in

    @Test func aDayBehindTodayIsItsOwnWindowAndDoesNotFollowNow() {
        let now = Self.local(20, 14, 32)
        var yesterday = TimelineWindow.day(ofMs: Self.local(19, 9), nowMs: now, clock: Self.stockholm)
        #expect(yesterday.fromMs == Self.local(19, 0))
        #expect(yesterday.toMs == Self.local(20, 0))
        #expect(!yesterday.isToday)
        #expect(!yesterday.followsNow)
        let held = yesterday
        yesterday.follow(nowMs: now + 3_600_000, clock: Self.stockholm)
        #expect(yesterday == held)
        // The day now is in is today's window, which rolls at midnight.
        let today = TimelineWindow.day(ofMs: now, nowMs: now, clock: Self.stockholm)
        #expect(today == TimelineWindow.today(nowMs: now, clock: Self.stockholm))
        #expect(today.isToday)
    }

    /// The window the price chart already draws, as one a finger can move:
    /// a chart that opened at the slot now is in does not jump when the
    /// move begins.
    @Test func aDrawnWindowBecomesOneThatCanBeMoved() {
        let now = Self.local(20, 14, 32)
        let drawn = TimelineWindow(fromMs: Self.local(20, 14, 30), toMs: Self.local(21, 14, 30), nowMs: now)
        #expect(drawn.fromMs == Self.local(20, 14, 30))
        #expect(drawn.spanMs == 24 * 3_600_000)
        #expect(drawn.followsNow)
        // Dragged a quarter of the width to the right: six hours earlier,
        // and the time under the finger goes with it. Now is still in the
        // window, so it keeps following now.
        let moved = drawn.transformed(anchor: 0.25, destination: 0.5, magnification: 1, nowMs: now)
        #expect(moved.time(at: 0.5) == drawn.time(at: 0.25))
        #expect(moved.followsNow)
        // A whole width back leaves now behind, and the window holds still.
        let back = drawn.transformed(anchor: 0, destination: 1, magnification: 1, nowMs: now)
        #expect(back.toMs == drawn.fromMs)
        #expect(!back.followsNow)
        // Never past the two days the box is asked for.
        let far = drawn.transformed(anchor: 1, destination: 0, magnification: 1, nowMs: now)
        #expect(far.fromMs == now + TimelineWindow.aheadMs - drawn.spanMs)
        let farBack = drawn.transformed(anchor: 0, destination: 10, magnification: 1, nowMs: now)
        #expect(farBack.fromMs == now - TimelineWindow.historyMs)
    }

    // MARK: A finger that moves a chart rather than reading it

    @Test func aMoveBeforeTheHoldMovesAChartThatCanBeMoved() {
        var pan = TouchIntent(at: CGPoint(x: 100, y: 50), ms: 0, pans: true)
        #expect(pan.moved(to: CGPoint(x: 93, y: 51), atMs: 40) == .pan)
        // Once it has decided it keeps the decision: a finger that runs on
        // and rests never starts reading mid-move.
        #expect(pan.moved(to: CGPoint(x: 40, y: 51), atMs: 400) == .pan)
        #expect(pan.lifted() == .pan)
    }

    @Test func aChartThatCannotBeMovedStillReadsOnTheMove() {
        var read = TouchIntent(at: CGPoint(x: 100, y: 50), ms: 0)
        #expect(read.moved(to: CGPoint(x: 93, y: 51), atMs: 40) == .scrub)
    }

    @Test func aFingerThatRestsReadsAndASecondFingerReadsAtOnce() {
        var held = TouchIntent(at: CGPoint(x: 100, y: 50), ms: 0, pans: true)
        #expect(held.held(atMs: TouchIntent.holdMs) == .scrub)
        #expect(held.moved(to: CGPoint(x: 40, y: 50), atMs: 400) == .scrub)

        var span = TouchIntent(at: CGPoint(x: 100, y: 50), ms: 0, pans: true)
        #expect(span.moved(to: CGPoint(x: 120, y: 50), atMs: 20, fingers: 2) == .scrub)

        // A touch that lifts without moving is still a tap.
        var tap = TouchIntent(at: CGPoint(x: 100, y: 50), ms: 0, pans: true)
        #expect(tap.lifted() == .tap)
    }

    // MARK: The chart of a day behind now

    @Test func aWindowBehindNowDrawsItsOwnDayWithNoNowAndNothingPending() {
        let now = Self.local(20, 14, 32)
        let chart = PriceChart.build(Self.quarters(19) { $0 < 6 ? 50 : 150 },
                                     currency: "SEK", nowMs: now, fromMs: Self.local(19, 0),
                                     spanMs: 24 * 3_600_000, clock: Self.stockholm)
        #expect(chart.grid.fromMs == Self.local(19, 0))
        #expect(chart.grid.toMs == Self.local(20, 0))
        #expect(chart.grid.count == 96)
        #expect(chart.nowIndex == nil)
        // Nothing is waiting for tomorrow's rates in a day that is over.
        #expect(chart.pending == nil)
        #expect(chart.pendingText.isEmpty)
        #expect(chart.meanText == "125")
        // The hour labels are there: a window with no now has no label to
        // keep clear of.
        #expect(chart.hours.map(\.label) == ["06", "12", "18"])
        #expect(chart.cheapestText == "CHEAPEST 00:00–02:00 · \(Words.decimal("50.0")) ÖRE")
    }

    /// A day the box has only part of: the slots it has no price for stay
    /// nil, and nothing claims the market said zero.
    @Test func aPastDayWithAHoleKeepsTheHoleAndIsNotPending() {
        let now = Self.local(20, 14, 32)
        let chart = PriceChart.build(Self.quarters(19, hours: 0..<12) { _ in 80 },
                                     currency: "SEK", nowMs: now, fromMs: Self.local(19, 0),
                                     spanMs: 24 * 3_600_000, clock: Self.stockholm)
        #expect(chart.minor[0] == 80)
        #expect(chart.minor[48] == nil)
        #expect(chart.minor[95] == nil)
        #expect(chart.pending == nil)
        #expect(chart.figure[48] == "—")
        #expect(chart.meanText == Words.decimal("80.0"))
    }

    /// Nothing about the window ahead moved: the chart still starts at the
    /// slot now is in when no window is given.
    @Test func withNoWindowTheChartStillOpensAtTheSlotNowIsIn() {
        let now = Self.local(20, 14, 32)
        let chart = PriceChart.build(Self.quarters(20) { _ in 90 } + Self.quarters(21) { _ in 110 },
                                     currency: "SEK", nowMs: now, clock: Self.stockholm)
        #expect(chart.grid.fromMs == Self.local(20, 14, 30))
        #expect(chart.nowIndex == 0)
        #expect(chart.grid.count == 96)
    }
}
