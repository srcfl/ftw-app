import Foundation
import Testing
@testable import FTWShared

/// Now's plan strip: the next twelve hours as 48 quarters, the sentence
/// under it and what a finger reads. The plan is `PlanGlanceTests.night()`:
/// from Monday 20:00 the battery gives power until 21:15, stores 22:00 to
/// 23:30 and gives power 06:00 to 08:00; the car charges 01:00 to 04:45
/// toward 80 %; power costs 30 öre 02–04, 160 öre 17–21 and 06–09, and
/// 70 öre otherwise. Stockholm's clock, English words.
@Suite struct PlanStripTests {
    let glance = PlanGlanceTests()
    var calendar: Calendar { glance.calendar }
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double { glance.at(day, hour, minute) }

    func strip(at t: Double, hasCar: Bool = true) -> PlanStrip {
        let entry = glance.night()
        return PlanStrip.build(entry, moment: PlanGlance.live(entry, nowMs: t, calendar: calendar), hasCar: hasCar)
    }

    @Test func fortyEightQuartersFromTheOneRunningNow() {
        let s = strip(at: at(12, 20, 5))
        #expect(s.grid.count == 48)
        #expect(s.grid.firstMs == at(12, 20))
        #expect(s.grid.toMs == at(13, 8))
        #expect(s.nowMs == at(12, 20, 5))
        #expect(s.readouts.count == 48 && s.levels.count == 48 && s.battery.count == 48 && s.car.count == 48)
    }

    /// Each lane draws one shape per stretch of equal quarters, so a run
    /// has no seams; a quarter in which the battery waits ends a run.
    @Test func theLanesAreRunsOfEqualQuarters() {
        let s = strip(at: at(12, 20, 5))
        #expect(s.batteryRuns == [
            .init(first: 0, count: 5, value: .gives),
            .init(first: 8, count: 6, value: .stores),
            .init(first: 40, count: 8, value: .gives),
        ])
        // 01:00 is quarter 20, and the last quarter before 04:45 is 34.
        #expect(s.carRuns == [.init(first: 20, count: 15, value: true)])
        #expect(s.goals == [34: 80])
        #expect(s.hasCar)
    }

    /// The price in eight levels across the window, and equal levels as one
    /// bar: 160 öre is the top, 30 the bottom, 70 sits at level 2.
    @Test func thePriceIsEightLevelsInRuns() {
        let s = strip(at: at(12, 20, 5))
        #expect(s.priceRuns.map(\.value) == [7, 2, 0, 2, 7])
        #expect(s.priceRuns.map(\.count) == [4, 20, 8, 8, 8])
        // The same height always takes the same ink.
        #expect(PlanStrip.third(0) == .cheap && PlanStrip.third(2) == .cheap)
        #expect(PlanStrip.third(3) == .middle && PlanStrip.third(4) == .middle)
        #expect(PlanStrip.third(5) == .dear && PlanStrip.third(7) == .dear)
        // A flat window sits in the middle.
        #expect(PlanStrip.level(70, lo: 70, hi: 70) == 3)
    }

    @Test func aFingerReadsTheQuarterAndBumpsOnItsLandmarks() {
        let s = strip(at: at(12, 20, 5))
        #expect(s.readouts[0] == "20:00 · 160 öre · gives power")
        #expect(s.readouts[5] == "21:15 · 70.0 öre · waits")
        #expect(s.readouts[8] == "22:00 · 70.0 öre · stores")
        #expect(s.readouts[24] == "02:00 · 30.0 öre · waits · car charges")
        #expect(s.readouts[34] == "04:30 · 70.0 öre · waits · car at 80\u{00A0}%")
        // Now and both ends, the cheapest two hours' edges, the car's goal.
        #expect(s.landmarks == [0, 47, 24, 31, 34])
    }

    @Test func hoursEveryThreeOnTheWallClock() {
        let s = strip(at: at(12, 20, 5))
        #expect(s.hours.map(\.label) == ["21", "00", "03", "06"])
        #expect(s.hours.first?.ms == at(12, 21))
    }

    /// From the cache the header says when the box made the plan; an hour
    /// on it says the plan is old and every mark goes grey.
    @Test func theHeaderDatesAKeptPlanAndGreysAnOldOne() {
        let entry = glance.night()
        #expect(strip(at: at(12, 20, 5)).kicker == "NEXT 12 H")
        let kept = PlanStrip.build(entry, moment: PlanGlance.kept(entry, readAtMs: at(12, 20), nowMs: at(12, 20, 30), calendar: calendar), hasCar: true)
        #expect(kept.kicker == "PLANNED 20:00")
        #expect(!kept.grey)
        let old = PlanStrip.build(entry, moment: PlanGlance.kept(entry, readAtMs: at(12, 20), nowMs: at(12, 21, 30), calendar: calendar), hasCar: true)
        #expect(old.kicker == "OLD PLAN · 20:00")
        #expect(old.grey)
    }

    /// No plan yet: no lanes and no battery word under a finger, never
    /// "waits", which would be a claim about a plan nobody sent.
    @Test func noPlanDrawsNoLanes() {
        var entry = glance.night()
        entry.battery = nil
        entry.charges = []
        let s = PlanStrip.build(entry, moment: PlanGlance.waiting(entry, nowMs: at(12, 20, 5), calendar: calendar), hasCar: false)
        #expect(s.batteryRuns.isEmpty && s.carRuns.isEmpty)
        #expect(!s.hasCar)
        #expect(s.readouts[0] == "20:00 · 160 öre")
        #expect(s.grey)
    }

    // MARK: The sentence under the strip

    /// The next thing and why, then the one after it and why: the price
    /// that drives it, or the car's goal.
    @Test func theSentenceSaysTheNextThingWhyAndWhatFollows() {
        func next(_ t: Double) -> String { PlanGlance.live(glance.night(), nowMs: t, calendar: calendar).nextText }
        // Under way: until when and why, then the next move and why.
        #expect(next(at(12, 20, 5)) == "Battery gives power until 21:15, when power costs up to 160 öre. Then stores 22:00 for 70.0 öre.")
        // To come: when it runs; the next subject is named.
        #expect(next(at(12, 21, 30)) == "Battery stores 22:00–23:30 for 70.0 öre. Then the car charges 01:00, to 80\u{00A0}%.")
        #expect(next(at(12, 23, 45)) == "Car charges 01:00–04:45, to 80\u{00A0}%. Then the battery gives power 06:00, when power costs up to 160 öre.")
        #expect(next(at(13, 2)) == "Car charges until 04:45, to 80\u{00A0}%. Then the battery gives power 06:00, when power costs up to 160 öre.")
        // The last thing in the plan stands alone.
        #expect(next(at(13, 7)) == "Battery gives power until 08:00, when power costs up to 160 öre.")
    }

    @Test func anOldPlanNeverSaysUntil() {
        let m = PlanGlance.kept(glance.night(), readAtMs: at(12, 18), nowMs: at(12, 20, 5), calendar: calendar)
        #expect(m.state == .old)
        #expect(m.nextText == "Battery gives power 20:05–21:15, when power costs up to 160 öre. Then stores 22:00 for 70.0 öre.")
    }

    /// Each reason says what drives the move; one with nothing to show
    /// leaves the clause bare.
    @Test func theReasonIsWhatDrivesTheMove() {
        let entry = glance.night()
        let clock = Clock(calendar: calendar)
        func said(_ kind: PlanGlance.Kind, _ reason: String, from: Double = at(12, 22), to: Double = at(12, 23)) -> String {
            let e = PlanGlance.Event(kind: kind, startMs: from, endMs: to, reason: reason)
            return PlanGlance.clause(e, entry: entry, from: at(12, 20), clock: clock, ongoingIsNow: true).plain
        }
        #expect(said(.charge, "solar_surplus") == "Battery stores 22:00–23:00 from spare sun.")
        #expect(said(.discharge, "export_paid") == "Battery gives power 22:00–23:00, as selling pays.")
        #expect(said(.discharge, "peak_shaving") == "Battery gives power 22:00–23:00 to hold the grid limit.")
        #expect(said(.charge, "cheap_import", from: at(13, 2), to: at(13, 4)) == "Battery stores 02:00–04:00 for 30.0 öre.")
        // No price under it: no reason with a number.
        #expect(said(.discharge, "expensive_import", from: at(14, 2), to: at(14, 3)) == "Battery gives power 02:00–03:00.")
        var paid = entry
        paid.prices = paid.prices.map { PriceSlot(startMs: $0.startMs, durationMs: $0.durationMs, spotMinor: -20, totalMinor: -5) }
        let e = PlanGlance.Event(kind: .charge, startMs: at(12, 22), endMs: at(12, 23), reason: "cheap_import")
        #expect(PlanGlance.clause(e, entry: paid, from: at(12, 20), clock: clock, ongoingIsNow: true).plain == "Battery stores 22:00–23:00, when you are paid to use power.")
    }

    /// Under the dial: the battery's next two moves and the car's charge, in
    /// order, each with its verb marked for its colour.
    @Test func theStoryUnderTheDial() {
        let m = PlanGlance.live(glance.night(), nowMs: at(12, 20, 5), calendar: calendar)
        #expect(m.story.map(\.kind) == [.discharge, .charge, .car])
        #expect(m.story.map(\.plain) == [
            "Battery gives power until 21:15, when power costs up to 160 öre.",
            "Battery stores 22:00–23:30 for 70.0 öre.",
            "Car charges 01:00–04:45, to 80\u{00A0}%.",
        ])
        #expect(m.story[0].parts == ["Battery ", "gives power", " until 21:15, when power costs up to 160 öre."])
        // Nothing to tell before the box has answered.
        #expect(PlanGlance.waiting(glance.night(), nowMs: at(12, 20), calendar: calendar).story.isEmpty)
    }

    @Test func theSentenceBeforeAndWithoutAPlan() {
        var entry = glance.night()
        #expect(PlanGlance.waiting(entry, nowMs: at(12, 20), calendar: calendar).nextText == "Reading the plan from your box…")
        entry.battery = []
        entry.charges = []
        #expect(PlanGlance.live(entry, nowMs: at(12, 20), calendar: calendar).nextText == "Nothing planned for 12 hours")
        entry.battery = nil
        #expect(PlanGlance.live(entry, nowMs: at(12, 20), calendar: calendar).nextText == "No plan from your box yet")
        entry.boxStale = true
        entry.battery = glance.night().battery
        #expect(PlanGlance.live(entry, nowMs: at(12, 20), calendar: calendar).nextText == "Your box couldn't plan ahead · it runs on safe defaults")
    }

    /// The box starts its plan the moment it makes it, so the first slot
    /// begins inside the quarter running now. That quarter still says what
    /// the battery does.
    @Test func theQuarterRunningNowReadsAPlanMadeInsideIt() {
        var entry = glance.night()
        let made = at(12, 20, 7)
        entry.battery = entry.battery.map { slots in
            [PlanEntry.Slot(startMs: made, durationMs: at(12, 20, 15) - made, batteryW: -1_800, reason: "expensive_import")] + slots.dropFirst()
        }
        let s = PlanStrip.build(entry, moment: PlanGlance.live(entry, nowMs: at(12, 20, 7), calendar: calendar), hasCar: true)
        #expect(s.battery[0] == .gives)
        #expect(s.readouts[0] == "20:00 · 160 öre · gives power")
        #expect(s.batteryRuns.first == .init(first: 0, count: 5, value: .gives))
    }
}
