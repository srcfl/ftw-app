import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire
import FTWDemo

/// The car view's rules: where a level comes from and how old it is, the
/// receipt under every command, the ready time the box really uses, and
/// whether the car makes it. In English unless a test says otherwise.
@Suite struct CarTextTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let stockholm = TimeZone(identifier: "Europe/Stockholm")!

    func lp(_ json: String) throws -> Loadpoint {
        Loadpoint(try JSON(parsing: Array(json.utf8)))
    }

    /// 2026-10-12 10:00:00 UTC.
    static let t: Double = 1_791_799_200_000

    // MARK: The level's origin and age

    @Test func theLevelSaysWhoSaidIt() throws {
        try AppWords.$language.withValue(.en) {
            let t = Self.t
            let assumed = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.2,"soc_source":"assumed"}"#)
            let a = try #require(EVText.level(assumed, answeredAtMs: t, nowMs: t))
            #expect(a.origin == .assumed)
            #expect(a.pct == 20)
            #expect(EVText.origin(a, zone: Self.utc) == "FTW assumes 20\u{00A0}%. Nobody has told it the real level.")
            #expect(EVText.originShort(a, zone: Self.utc) == "FTW assumes")

            let estimated = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.46,"soc_source":"inferred"}"#)
            #expect(EVText.level(estimated, answeredAtMs: t, nowMs: t)?.origin == .estimated)

            // Set from this phone: said as such, and once the box has added
            // what charged since, both numbers are honest.
            let set = EVText.LevelSet(pct: 40, atMs: t - 600_000)
            let you = try #require(EVText.level(estimated, answeredAtMs: t, nowMs: t, set: set))
            #expect(you.origin == .you)
            #expect(you.pct == 46)
            #expect(EVText.origin(you, zone: Self.utc) == "You set 40\u{00A0}% at 09:50. FTW adds what has charged since.")
            let same = try #require(EVText.level(try lp(#"{"id":"a","plugged_in":true,"current_soc":0.4,"soc_source":"inferred"}"#), answeredAtMs: t, nowMs: t, set: set))
            #expect(EVText.origin(same, zone: Self.utc) == "You set 40\u{00A0}% at 09:50")

            let completed = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.8,"soc_source":"completed"}"#)
            #expect(EVText.level(completed, answeredAtMs: t, nowMs: t)?.origin == .unconfirmed)

            // No car on the cable: no level, and none offered.
            #expect(EVText.level(try lp(#"{"id":"a","plugged_in":false,"current_soc":0.6}"#), answeredAtMs: t, nowMs: t) == nil)
        }
    }

    /// Core plans from a car's report for five minutes. Older than that the
    /// view still shows it, dated "last reported HH:MM".
    @Test func aCarsLevelOlderThanFiveMinutesIsDated() throws {
        try AppWords.$language.withValue(.en) {
            let t = Self.t
            let fresh = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.6,"soc_source":"vehicle","vehicle_driver":"vag","vehicle_soc":0.64,"vehicle_soc_age_s":300}"#)
            let f = try #require(EVText.level(fresh, answeredAtMs: t, nowMs: t))
            #expect(f.origin == .car)
            #expect(f.pct == 64)
            #expect(EVText.origin(f, zone: Self.utc) == "From the car")

            let old = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.6,"soc_source":"inferred","vehicle_driver":"vag","vehicle_soc":0.64,"vehicle_soc_age_s":301}"#)
            let o = try #require(EVText.level(old, answeredAtMs: t, nowMs: t))
            #expect(o.origin == .carEarlier)
            #expect(o.atMs == t - 301_000)
            #expect(EVText.origin(o, zone: Self.utc) == "From the car, last reported 09:54")
            #expect(EVText.originShort(o, zone: Self.utc) == "reported 09:54")

            // The same answer ages on screen: two minutes later it is dated.
            #expect(EVText.level(fresh, answeredAtMs: t, nowMs: t + 120_000)?.origin == .carEarlier)

            // The box's own stale flag dates it whatever the age.
            let flagged = try lp(#"{"id":"a","plugged_in":true,"soc_source":"inferred","vehicle_driver":"vag","vehicle_soc":0.5,"vehicle_soc_age_s":10,"vehicle_stale":true}"#)
            #expect(EVText.level(flagged, answeredAtMs: t, nowMs: t)?.origin == .carEarlier)

            // A box without vehicle_soc still dates a vehicle level by its age.
            let legacy = try lp(#"{"id":"a","plugged_in":true,"current_soc":0.6,"soc_source":"vehicle","vehicle_soc_age_s":900}"#)
            #expect(EVText.level(legacy, answeredAtMs: t, nowMs: t)?.origin == .carEarlier)

            // A level set here after the car's last report wins.
            let later = EVText.LevelSet(pct: 70, atMs: t - 60_000)
            #expect(EVText.level(old, answeredAtMs: t, nowMs: t, set: later)?.origin == .you)
            let earlier = EVText.LevelSet(pct: 70, atMs: t - 900_000)
            #expect(EVText.level(old, answeredAtMs: t, nowMs: t, set: earlier)?.origin == .carEarlier)
        }
    }

    @Test func theLevelInSwedish() throws {
        try AppWords.$language.withValue(.sv) {
            let t = Self.t
            let assumed = try #require(EVText.level(try lp(#"{"id":"a","plugged_in":true,"current_soc":0.2,"soc_source":"assumed"}"#), answeredAtMs: t, nowMs: t))
            #expect(EVText.origin(assumed, zone: Self.utc) == "FTW antar 20\u{00A0}%. Ingen har angett den riktiga nivån.")
            let old = try #require(EVText.level(try lp(#"{"id":"a","plugged_in":true,"soc_source":"inferred","vehicle_driver":"vag","vehicle_soc":0.64,"vehicle_soc_age_s":2400}"#), answeredAtMs: t, nowMs: t))
            #expect(EVText.origin(old, zone: Self.stockholm) == "Från bilen, senast rapporterad 11:20")
            let you = EVText.Level(pct: 40, origin: .you, atMs: t, setPct: nil)
            #expect(EVText.origin(you, zone: Self.stockholm) == "Du angav 40\u{00A0}% kl. 12:00")
            #expect(EVText.status(try lp(#"{"id":"a","plugged_in":true,"current_power_w":7200}"#)) == "Laddar med 7,2\u{00A0}kW")
        }
    }

    @Test func plusAndMinusMoveByFive() {
        #expect(EVText.stepped(41, up: true) == 45)
        #expect(EVText.stepped(41, up: false) == 40)
        #expect(EVText.stepped(40, up: true) == 45)
        #expect(EVText.stepped(40, up: false) == 35)
        #expect(EVText.stepped(100, up: true) == 100)
        #expect(EVText.stepped(0, up: false) == 0)
    }

    // MARK: The outcome row

    @Test func theReceiptFollowsAckAndResult() throws {
        try AppWords.$language.withValue(.en) {
            let sending = EVText.outcome(EVText.Step(ask: .level(40)), nil)
            #expect(sending.sent == .done && sending.received == .active && sending.done == .waiting)
            #expect(sending.tone == .working)
            #expect(sending.text == "Sending 40\u{00A0}% to FTW…")

            let received = EVText.outcome(EVText.Step(ask: .level(40), acked: true), nil)
            #expect(received.received == .done && received.done == .active)
            #expect(received.text == "FTW received 40\u{00A0}%.")

            let done = EVText.outcome(EVText.Step(ask: .level(40), acked: true, result: .applied(observed: 0.4)), nil)
            #expect(done.received == .done && done.done == .done && done.tone == .done)
            #expect(done.text == "FTW now plans from 40\u{00A0}%.")

            let superseded = EVText.outcome(EVText.Step(ask: .level(40), acked: true, result: .superseded(observed: 0.45)), nil)
            #expect(superseded.done == .failed && superseded.tone == .warning)
            #expect(superseded.text == "FTW kept 45\u{00A0}%. A newer level came first.")

            let unconfirmed = EVText.outcome(EVText.Step(ask: .chargeNow, acked: true, result: .unconfirmed(note: nil)), nil)
            #expect(unconfirmed.done == .waiting && unconfirmed.tone == .warning)
            #expect(unconfirmed.text == "FTW received it but has not confirmed the result yet.")

            // Refused after the box took it, and never reaching it at all.
            let why = EVText.refusal(CmdResult(cmdId: "c", state: .rejected, errorCode: "E_UNAVAILABLE", errorArgs: ["reason": .text("unplugged")]))
            #expect(why == "Plug the car in first. FTW takes a level only while the car is plugged in.")
            let refused = EVText.outcome(EVText.Step(ask: .level(40), acked: true, result: .refused(why)), nil)
            #expect(refused.received == .done && refused.done == .failed && refused.tone == .failed)
            #expect(refused.text == why)
            let lost = EVText.outcome(EVText.Step(ask: .chargeNow, result: .refused(EVText.failure(CommandError(code: "E_NO_ACK", help: "")))), nil)
            #expect(lost.received == .failed && lost.done == .failed)
            #expect(lost.text == "Did not reach FTW. Try again.")
            #expect(EVText.failure(SessionError.noCarrier) == "Not connected to FTW right now. Try again when the connection is back.")

            // Done for Charge now means the box holds it; the charger's own
            // account says whether the car takes it.
            let started = EVText.Step(ask: .chargeNow, acked: true, result: .applied(observed: 11_000))
            #expect(EVText.outcome(started, nil).text == "FTW started charging. Waiting for the car to draw power.")
            let drawing = try lp(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":11000,"current_power_w":11000,"manual":{"state":"charging"}}"#)
            #expect(EVText.outcome(started, drawing).text == "Charging at 11\u{00A0}kW. The plan waits until you go back to it.")
            let refusing = try lp(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":11000,"manual":{"state":"not_drawing"}}"#)
            #expect(EVText.outcome(started, refusing).text == "The car is not taking power. Check the car's charge limit.")
            #expect(EVText.outcome(EVText.Step(ask: .resume, acked: true, result: .applied(observed: 0)), nil).text == "Back to the plan. FTW decides when to charge.")
        }
    }

    @Test func theReceiptInSwedish() {
        AppWords.$language.withValue(.sv) {
            let r = EVText.outcome(EVText.Step(ask: .chargeNow, acked: true), nil)
            #expect(r.text == "FTW har tagit emot det.")
            #expect(EVText.outcome(EVText.Step(ask: .pause, acked: true, result: .applied(observed: 0)), nil).text == "Pausad. Bilen laddar inte förrän du väljer.")
            #expect(AppWords.text("Sent") == "Skickat")
            #expect(AppWords.text("Received") == "Mottaget")
            #expect(AppWords.text("Done") == "Utfört")
        }
    }

    // MARK: The ready time over 25 October 2026

    static func noon(_ day: Int, _ month: Int = 10) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = stockholm
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    static func utcDate(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// Summer time ends on 25 October 2026. 07:00 is 05:00 UTC before and
    /// 06:00 UTC after; the box keeps 07:00 and answers with today's minute.
    @Test func theReadyTimeIsTheHouseholdClockAcrossOctober25() throws {
        let z = Self.stockholm
        #expect(EVText.minuteUTC(clock: 420, at: Self.noon(24), zone: z) == 300)
        #expect(EVText.minuteUTC(clock: 420, at: Self.noon(25), zone: z) == 360)
        #expect(EVText.minuteUTC(clock: 420, at: Self.noon(26), zone: z) == 360)
        #expect(EVText.clockFromUTC(300, at: Self.noon(24), zone: z) == 420)
        #expect(EVText.clockFromUTC(360, at: Self.noon(25), zone: z) == 420)
        #expect(EVText.clockFromUTC(360, at: Self.noon(26), zone: z) == 420)
        // A box that kept the UTC minute really charges by 06:00 after the
        // change, and the view says 06:00 rather than the 07:00 once asked.
        #expect(EVText.clockFromUTC(300, at: Self.noon(26), zone: z) == 360)

        // The hour that happens twice counts its first pass; the hour that
        // never happens (29 March) gives the end of the gap. Core does both.
        #expect(EVText.minuteUTC(clock: 150, at: Self.noon(25), zone: z) == 30)
        #expect(EVText.minuteUTC(clock: 150, at: Self.noon(29, 3), zone: z) == 60)
    }

    @Test func theGoalShowsTheWallTimeTheBoxUses() throws {
        try AppWords.$language.withValue(.en) {
            let z = Self.stockholm
            let before = try lp(#"{"id":"a","plugged_in":true,"schedule":{"soc":0.8,"time_of_day_min_utc":300,"recurring":true,"days":31}}"#)
            let after = try lp(#"{"id":"a","plugged_in":true,"schedule":{"soc":0.8,"time_of_day_min_utc":360,"recurring":true,"days":31}}"#)
            let clocked = try lp(#"{"id":"a","plugged_in":true,"schedule":{"soc":0.8,"time_of_day_min_utc":300,"time_of_day_min":420,"recurring":true,"days":31}}"#)
            #expect(EVText.goal(try #require(before.schedule), at: Self.noon(24), zone: z) == "80\u{00A0}% by 07:00 on weekdays")
            #expect(EVText.goal(try #require(after.schedule), at: Self.noon(26), zone: z) == "80\u{00A0}% by 07:00 on weekdays")
            // A box that sends the household clock is read as it says.
            #expect(EVText.goal(try #require(clocked.schedule), at: Self.noon(26), zone: z) == "80\u{00A0}% by 07:00 on weekdays")

            // From Saturday noon the next weekday 07:00 is Monday, in winter time.
            let next = EVText.nextDeadlineMs(try #require(before.schedule), nowMs: Self.noon(24).timeIntervalSince1970 * 1000, zone: z)
            #expect(next == Self.utcDate("2026-10-26T06:00:00Z").timeIntervalSince1970 * 1000)
            var daily = try #require(before.schedule)
            daily.days = 0
            let sunday = EVText.nextDeadlineMs(daily, nowMs: Self.noon(24).timeIntervalSince1970 * 1000, zone: z)
            #expect(sunday == Self.utcDate("2026-10-25T06:00:00Z").timeIntervalSince1970 * 1000)
        }
        AppWords.$language.withValue(.sv) {
            let s = Loadpoint.Schedule(socPct: 80, timeOfDayMinUTC: 300, clockMin: nil, surplusUnlockPct: 0, recurring: true, days: 0b0011111, finishAtVehicleLimit: false)
            #expect(EVText.goal(s, at: Self.noon(24), zone: Self.stockholm) == "80\u{00A0}% till 07:00 vardagar")
        }
    }

    @Test func theHouseholdZoneIsTheBoxsWhenItNamesOne() throws {
        let phone = TimeZone(identifier: "America/New_York")!
        #expect(EVText.householdZone(boxTZ: "Europe/Stockholm", phone: phone) == Self.stockholm)
        #expect(EVText.householdZone(boxTZ: "Local", phone: phone) == phone)
        #expect(EVText.householdZone(boxTZ: "UTC", phone: phone) == phone)
        #expect(EVText.householdZone(boxTZ: "", phone: phone) == phone)
        #expect(EVText.householdZone(boxTZ: "Not/AZone", phone: phone) == phone)
        try AppWords.$language.withValue(.en) {
            let away = try lp(#"{"id":"a","plugged_in":true,"schedule":{"soc":0.8,"time_of_day_min_utc":300,"recurring":true,"days":0}}"#)
            let now = Self.noon(24).timeIntervalSince1970 * 1000
            #expect(EVText.nextGoal(away, nowMs: now, zone: Self.stockholm, phone: phone) == "Next: tomorrow 07:00, home time")
            #expect(EVText.nextGoal(away, nowMs: now, zone: Self.stockholm, phone: Self.stockholm) == "Next: tomorrow 07:00")
        }
    }

    // MARK: Will the car be ready?

    @Test func readinessComesFromThePlansShortfall() throws {
        try AppWords.$language.withValue(.en) {
            let z = Self.stockholm
            let now = Self.noon(24).timeIntervalSince1970 * 1000
            let json = #"{"id":"a","plugged_in":true,"current_soc":0.35,"soc_source":"inferred","vehicle_capacity_wh":64000,"target_time":"2026-10-25T06:00:00Z","schedule":{"soc":0.8,"time_of_day_min_utc":360,"recurring":true,"days":0}}"#
            let car = try lp(json)
            let level = EVText.level(car, answeredAtMs: now, nowMs: now)
            #expect(EVText.readiness(car, level: level, shortfallWh: 0, nowMs: now, zone: z) == .onTrack(targetPct: 80, byMs: Self.utcDate("2026-10-25T06:00:00Z").timeIntervalSince1970 * 1000))
            let short = try #require(EVText.readiness(car, level: level, shortfallWh: 18_200, nowMs: now, zone: z))
            #expect(short == .short(reachPct: 51, targetPct: 80, byMs: Self.utcDate("2026-10-25T06:00:00Z").timeIntervalSince1970 * 1000))
            #expect(EVText.readiness(short, level: level, nowMs: now, zone: z) == "Will not make it: about 51\u{00A0}% by tomorrow 07:00, not 80\u{00A0}%.")
            #expect(EVText.readiness(.onTrack(targetPct: 80, byMs: now + 3_600_000), level: level, nowMs: now, zone: z) == "On track: 80\u{00A0}% by today 13:00.")

            // From a guess, it says so.
            let guessed = EVText.Level(pct: 20, origin: .assumed, atMs: nil, setPct: nil)
            #expect(EVText.readiness(.onTrack(targetPct: 80, byMs: now + 3_600_000), level: guessed, nowMs: now, zone: z).hasSuffix("Counted from FTW's guess of 20\u{00A0}%."))

            // Nothing claimed without the box's word.
            #expect(EVText.readiness(car, level: level, shortfallWh: nil, nowMs: now, zone: z) == nil)
            let pending = try lp(json.replacingOccurrences(of: #""id":"a","#, with: #""id":"a","plan_pending":true,"#))
            #expect(EVText.readiness(pending, level: level, shortfallWh: 0, nowMs: now, zone: z) == nil)
            let holding = try lp(json.replacingOccurrences(of: #""id":"a","#, with: #""id":"a","manual_active":true,"#))
            #expect(EVText.readiness(holding, level: level, shortfallWh: 0, nowMs: now, zone: z) == nil)
            let done = try lp(json.replacingOccurrences(of: #""id":"a","#, with: #""id":"a","goal_complete":true,"#))
            #expect(EVText.readiness(done, level: level, shortfallWh: nil, nowMs: now, zone: z) == .reached)
        }
    }

    // MARK: Is FTW in control?

    static func source(_ kind: String, _ name: String, _ state: String) -> Source {
        Source(.map([("kind", .text(kind)), ("name", .text(name)), ("lastOkMs", .int(0)), ("staleAfterMs", .int(10_000)), ("state", .text(state))]))!
    }

    @Test func inControlComesFromTheStreamAndIsNeverGreenFromACache() {
        AppWords.$language.withValue(.en) {
            let live = ["meter": Self.source("meter", "sdm630", "live"), "inverter": Self.source("inverter", "sungrow", "live")]
            let ok = InControl.answer(streaming: true, lastKnownMs: nil, dispatchBlockedBy: [], sources: live)
            #expect(ok.tone == .ok)
            #expect(ok.title == "Yes, FTW is in control")

            // The same facts from a cache, or from a stream gone quiet, are not a yes.
            let cached = InControl.answer(streaming: false, lastKnownMs: Self.t, dispatchBlockedBy: [], sources: live, zone: Self.utc)
            #expect(cached.tone == .stale)
            #expect(cached.title == "Not live right now")
            #expect(cached.detail == "Last known 10:00.")

            #expect(InControl.answer(streaming: true, lastKnownMs: nil, dispatchBlockedBy: ["meter"], sources: live).tone == .warning)

            var quiet = live
            quiet["inverter"] = Self.source("inverter", "sungrow", "down")
            let one = InControl.answer(streaming: true, lastKnownMs: nil, dispatchBlockedBy: [], sources: quiet)
            #expect(one.tone == .warning)
            #expect(one.title == "The inverter is not reporting")
            #expect(one.detail == "sungrow")
            quiet["meter"] = Self.source("meter", "sdm630", "stale")
            #expect(InControl.answer(streaming: true, lastKnownMs: nil, dispatchBlockedBy: [], sources: quiet).title == "2 devices are not reporting")
        }
        AppWords.$language.withValue(.sv) {
            #expect(InControl.answer(streaming: true, lastKnownMs: nil, dispatchBlockedBy: [], sources: [:]).title == "Ja, FTW styr")
            #expect(AppWords.text("Is FTW in control?") == "Styr FTW?")
        }
    }
}

/// The car view against the simulated box: plug in, give a level, set a
/// goal, Charge now and back to the plan, and every receipt on the way.
@MainActor
@Suite struct CarFlowTests {
    @MainActor
    final class Rig {
        let scheduler: ManualScheduler
        var box: SimulatedBox?
        var app: AppModel!

        init(nowMs: Double = CarTextTests.t) {
            scheduler = ManualScheduler(nowMs: nowMs)
            app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { [unowned self] s in
                let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
                box.resultDelayMs = 900
                box.house.chargerRampMs = 4_000
                self.box = box
                return LoopbackCarrier(box: box, scheduler: s)
            })
        }

        func run(_ ms: Double, step: Double = 50) async {
            var left = ms
            while left > 0 {
                for _ in 0..<10 { await Task.yield() }
                scheduler.advance(min(step, left))
                left -= step
            }
            for _ in 0..<10 { await Task.yield() }
        }
    }

    @Test func plugInGiveALevelSetAGoalAndChargeNow() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let box = try #require(rig.box)
            home.loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(home.loadpoints.points.first)
            #expect(car.pluggedIn)
            #expect(home.loadpoints.zone == CarTextTests.stockholm)
            #expect(home.loadpoints.level(car)?.origin == .assumed)
            #expect(home.loadpoints.level(car)?.pct == 20)

            // The level: sent, received, done, and then "you set".
            let level = Task { await home.loadpoints.setLevel(car, pct: 40) }
            await rig.run(100)
            #expect(home.loadpoints.levelStep[car.id] == EVText.Step(ask: .level(40)))
            // The tap shows as the chosen chip, never as the level: only the
            // box's answer moves the number.
            #expect(home.loadpoints.chosenLevel(car) == 40)
            #expect(home.loadpoints.level(car)?.pct == 20)
            #expect(home.loadpoints.level(car)?.origin == .assumed)
            await rig.run(300)
            #expect(home.loadpoints.levelStep[car.id]?.acked == true)
            #expect(home.loadpoints.levelStep[car.id]?.result == nil)
            await rig.run(1_500)
            await level.value
            #expect(home.loadpoints.levelStep[car.id]?.result == .applied(observed: 0.4))
            #expect(box.receivedCommands.last == Contract.opLoadpointSocSet)
            let after = try #require(home.loadpoints.points.first)
            #expect(home.loadpoints.level(after)?.origin == .you)
            #expect(home.loadpoints.level(after)?.pct == 40)

            // Three quick taps send the last one, not three.
            let sent = box.receivedCommands.count
            let a = Task { await home.loadpoints.setLevel(after, pct: 45) }
            let b = Task { await home.loadpoints.setLevel(after, pct: 50) }
            let c = Task { await home.loadpoints.setLevel(after, pct: 55) }
            await rig.run(5_000)
            await a.value; await b.value; await c.value
            #expect(box.receivedCommands.count - sent == 2)
            #expect(box.house.carSocFraction == 0.55)

            // The goal, saved as the household clock, read back on it.
            await home.loadpoints.saveGoalAndWait(car, rig, socPct: 90, clock: 6 * 60 + 30, recurring: true, days: 0b0011111)
            #expect(box.house.schedule?.clockMin == 390)
            #expect(home.loadpoints.goalSave[car.id] == .saved)
            let goal = try #require(home.loadpoints.points.first?.schedule)
            #expect(EVText.goal(goal, at: Date(timeIntervalSince1970: CarTextTests.t / 1000), zone: home.loadpoints.zone) == "90\u{00A0}% by 06:30 on weekdays")

            // Whether it makes it comes from the plan's shortfall.
            home.loadpoints.watchPlan()
            await rig.run(6_000, step: 100)
            #expect(home.loadpoints.shortfallWh[car.id] != nil)
            let withGoal = try #require(home.loadpoints.points.first)
            #expect(home.loadpoints.readiness(withGoal) != nil)
            home.loadpoints.unwatchPlan()

            // Charge now: no time limit, the charger's full current.
            let charge = Task { await home.loadpoints.chargeNow(withGoal) }
            await rig.run(400)
            #expect(home.loadpoints.holdStep[car.id]?.acked == true)
            #expect(home.loadpoints.holdSending(withGoal))
            await rig.run(1_500)
            await charge.value
            #expect(home.loadpoints.holdStep[car.id]?.result == .applied(observed: 11_000))
            #expect(box.house.manualHoldW == 11_000)
            await rig.run(5_000, step: 100)
            home.loadpoints.reread()
            await rig.run(500)
            let charging = try #require(home.loadpoints.points.first)
            #expect(charging.manualActive)
            #expect(charging.powerW == 11_000)
            #expect(home.loadpoints.outcome(hold: charging)?.text == "Charging at 11\u{00A0}kW. The plan waits until you go back to it.")
            // A plan set aside says nothing about the goal.
            #expect(home.loadpoints.readiness(charging) == nil)

            let back = Task { await home.loadpoints.backToPlan(charging) }
            await rig.run(2_000)
            await back.value
            #expect(home.loadpoints.outcome(hold: charging)?.text == "Back to the plan. FTW decides when to charge.")
            #expect(home.loadpoints.points.first?.manualActive == false)
            // A success fades once its effect is on screen.
            await rig.run(LoadpointsModel.doneShownMs + 1_000, step: 500)
            #expect(home.loadpoints.holdStep[car.id] == nil)
        }
    }

    @Test func unpluggedTakesNoLevelAndSaysWhy() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let box = try #require(rig.box)
            home.loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(home.loadpoints.points.first)
            let set = Task { await home.loadpoints.setLevel(car, pct: 60) }
            await rig.run(2_000)
            await set.value
            #expect(home.loadpoints.levelSet[car.id] != nil)

            box.setCarPluggedIn(false)
            home.loadpoints.reread()
            await rig.run(1_000)
            let out = try #require(home.loadpoints.points.first)
            #expect(!out.pluggedIn)
            #expect(home.loadpoints.level(out) == nil)
            #expect(home.loadpoints.levelSet[car.id] == nil)

            // The view offers no level now; if one is sent anyway, the box's
            // refusal reads as what to do.
            let refused = Task { await home.loadpoints.setLevel(out, pct: 60) }
            await rig.run(2_000)
            await refused.value
            #expect(home.loadpoints.outcome(level: out)?.text == "Plug the car in first. FTW takes a level only while the car is plugged in.")
            #expect(home.loadpoints.outcome(level: out)?.tone == .failed)

            // Plugging in again starts over: FTW assumes 20 %.
            box.setCarPluggedIn(true)
            home.loadpoints.reread()
            await rig.run(1_000)
            let back = try #require(home.loadpoints.points.first)
            #expect(home.loadpoints.level(back)?.origin == .assumed)
            #expect(home.loadpoints.level(back)?.pct == 20)
        }
    }

    /// Charge now walks the receipt log in the order its evidence comes:
    /// SENT at the tap, ACCEPTED on the box's ack, CONFIRMED on its result,
    /// and MEASURED only once lane 0 shows the car drawing, here four
    /// seconds later as the charger ramps. It fades 20 s after its last
    /// slot lit.
    @Test func chargeNowWalksTheReceiptOnItsEvidence() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let box = try #require(rig.box)
            box.setCarPluggedIn(true)
            home.loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(home.loadpoints.points.first)
            #expect(car.pluggedIn)
            #expect(box.house.evWatts == 0)
            @MainActor func marks() -> [ReceiptLog.Mark.State]? { home.loadpoints.receipt(hold: car)?.marks.map(\.state) }

            let charge = Task { await home.loadpoints.chargeNow(car) }
            for _ in 0..<10 { await Task.yield() }
            #expect(marks() == [.lit, .waiting, .waiting, .waiting])
            await rig.run(400)
            #expect(marks() == [.lit, .lit, .waiting, .waiting])
            await rig.run(1_500)
            await charge.value
            #expect(marks() == [.lit, .lit, .waiting, .lit])
            await rig.run(5_000, step: 100)
            #expect(marks() == [.lit, .lit, .lit, .lit])
            #expect(home.loadpoints.receipt(hold: car)?.line == "SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED")
            await rig.run(LoadpointsModel.doneShownMs + 1_500, step: 500)
            #expect(home.loadpoints.holdStep[car.id] == nil)
        }
    }

    /// The box's refusal takes the last slot with its reason, and a level's
    /// receipt has no MEASURED.
    @Test func aRefusedLevelSaysWhyInTheLastSlot() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let box = try #require(rig.box)
            box.setCarPluggedIn(false)
            home.loadpoints.activate()
            await rig.run(1_500)
            let out = try #require(home.loadpoints.points.first)
            let refused = Task { await home.loadpoints.setLevel(out, pct: 60) }
            await rig.run(2_000)
            await refused.value
            let receipt = try #require(home.loadpoints.receipt(level: out))
            #expect(receipt.line == "SENT ▸ ACCEPTED ▸ REFUSED")
            #expect(receipt.refused == "Plug the car in first. FTW takes a level only while the car is plugged in.")
            #expect(receipt.marks.last?.state == .refused)
        }
    }

    /// MEASURED means lane 0 shows what was asked: drawing for Charge now,
    /// still for Pause, the plan's own for Back to the plan; never a level.
    @Test func measuredMeansWhatWasAsked() {
        #expect(LoadpointsModel.measures(.chargeNow, evW: 7_400, planCharges: false))
        #expect(!LoadpointsModel.measures(.chargeNow, evW: 42, planCharges: false))
        #expect(LoadpointsModel.measures(.pause, evW: 0, planCharges: true))
        #expect(!LoadpointsModel.measures(.pause, evW: 7_400, planCharges: false))
        #expect(LoadpointsModel.measures(.resume, evW: 0, planCharges: false))
        #expect(LoadpointsModel.measures(.resume, evW: 11_000, planCharges: true))
        #expect(!LoadpointsModel.measures(.resume, evW: 0, planCharges: true))
        #expect(!LoadpointsModel.measures(.level(60), evW: 7_400, planCharges: true))
        let step = EVText.Step(ask: .chargeNow, acked: true, result: .superseded(observed: nil))
        #expect(EVText.receipt(step, nil).refused == "Something else changed charging first. Try again.")
    }

    /// The demo answers "Is FTW in control?" from the stream alone.
    @Test func theDemoSaysFTWIsInControl() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        await rig.run(3_000)
        let site = home.site
        let answer = InControl.answer(streaming: site.isLive, lastKnownMs: site.lastFrameAtMs, dispatchBlockedBy: site.session.dispatchBlockedBy, sources: site.session.sources)
        #expect(answer.tone == .ok)
        // No request was needed for it.
        #expect(try #require(rig.box).receivedRequests.isEmpty)
    }

    /// No timer reads the chargers, and no screen appearing while the
    /// last read stands. A command does, and the stream saying the car
    /// started drawing does.
    @Test func theChargersAreReadOnEventsNotOnATimer() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        func reads() -> Int { box.receivedRequests.filter { $0 == "GET /api/loadpoints" }.count }
        home.loadpoints.activate()
        await rig.run(1_000)
        #expect(reads() == 1)
        await rig.run(60_000, step: 500)
        #expect(reads() == 1)

        // A second screen appearing is no reason to look again: what the
        // first one shows is the box's answer.
        home.loadpoints.activate()
        await rig.run(1_000)
        #expect(reads() == 1)
        home.loadpoints.deactivate()

        // Charge now: one read after the box's answer, one when the stream
        // shows the car drawing power.
        let car = try #require(home.loadpoints.points.first)
        let charge = Task { await home.loadpoints.chargeNow(car) }
        await rig.run(2_000)
        await charge.value
        #expect(reads() == 2)
        #expect(home.loadpoints.points.first?.powerW == 0)
        await rig.run(5_000, step: 250)
        #expect(reads() == 3)
        #expect(home.loadpoints.points.first?.powerW == 11_000)
        await rig.run(60_000, step: 500)
        #expect(reads() == 3)

        // The plan's shortfall: read when the car view opens and when the
        // car's plan changes, not once a minute.
        let back = Task { await home.loadpoints.backToPlan(car) }
        await rig.run(3_000)
        await back.value
        func plans() -> Int { box.receivedRequests.filter { $0 == "GET /api/mpc/plan" }.count }
        home.loadpoints.watchPlan()
        await rig.run(1_000)
        #expect(plans() == 1)
        await rig.run(180_000, step: 1_000)
        #expect(plans() == 1)
    }

    /// A cold start paints the car the app last saw, from the cache it
    /// writes for its widgets, dated and marked as not live.
    @Test func aColdStartPaintsTheCarFromTheCache() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-car-\(UUID().uuidString)")
        let shared = AppGroupFiles(directory: dir)
        let readAt = CarTextTests.t - 600_000
        let car = CarEntry.Car(loadpointID: "garage", pluggedIn: true, socPct: 64, socSource: "vehicle", socReadAtMs: readAt - 120_000, powerW: 0, targetSocPct: 80)
        try shared.write(CacheRecord(siteId: "site-1", carrier: .relay, srcState: .live, readAtMs: readAt, value: CarEntry(cars: [car])))
        let scheduler = ManualScheduler(nowMs: CarTextTests.t)
        let site = SiteModel(siteId: "site-1", build: "test", ua: "test", scheduler: scheduler, files: nil)
        let model = LoadpointsModel(site: site, charging: nil, cache: CacheReader(sources: [shared]))
        let lp = try #require(model.points.first)
        #expect(model.fromCache)
        #expect(model.stale)
        #expect(model.readAtMs == readAt)
        #expect(lp.pluggedIn)
        #expect(lp.targetSocPct == 80)
        let level = try #require(model.level(lp))
        #expect(level.pct == 64)
        // The car's report was two minutes old when cached, ten minutes ago.
        #expect(level.origin == .carEarlier)
        #expect(level.atMs == readAt - 120_000)
        // Another home's cache paints nothing.
        let other = SiteModel(siteId: "site-2", build: "test", ua: "test", scheduler: scheduler, files: nil)
        #expect(LoadpointsModel(site: other, charging: nil, cache: CacheReader(sources: [shared])).points.isEmpty)
    }

    /// A save sends the household clock and today's UTC minute, built from
    /// nothing read. A Core with srcfl/ftw#1586 takes the clock; an older
    /// one reads the minute on today's date. Either way 07:00 is kept.
    @Test func aGoalSavesBothClocksAndEitherCoreKeepsTheTime() async throws {
        for (day, utc) in [(24, 300), (26, 360)] {
            for household in [true, false] {
                let rig = Rig(nowMs: CarTextTests.noon(day).timeIntervalSince1970 * 1000)
                rig.app.startDemo()
                let home = try #require(rig.app.home)
                let box = try #require(rig.box)
                box.readsHouseholdClock = household
                home.loadpoints.activate()
                await rig.run(1_500)
                let car = try #require(home.loadpoints.points.first)
                await home.loadpoints.saveGoalAndWait(car, rig, socPct: 80, clock: 7 * 60, recurring: true, days: 0b0011111)
                let body = try #require(box.lastScheduleBody)
                #expect(body["time_of_day_min"]?.number == 420)
                #expect(body["time_of_day_min_utc"]?.number == Double(utc))
                #expect(box.house.schedule?.clockMin == 420)
                // Read back: the clock when the box sends it, the minute otherwise.
                let back = try #require(home.loadpoints.points.first?.schedule)
                #expect(back.clockMin == (household ? 420 : nil))
                #expect(back.timeOfDayMinUTC == utc)
                #expect(EVText.goalClock(back, at: CarTextTests.noon(day), zone: home.loadpoints.zone) == 420)
            }
        }
    }

    /// Every demo situation opens, so each screen can be shown without a box.
    @Test func everyDemoCarOpens() async throws {
        for situation in DemoCar.allCases {
            let rig = Rig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            situation.apply(to: try #require(rig.box).house, nowMs: rig.scheduler.nowMs)
            home.loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(home.loadpoints.points.first)
            switch situation {
            case .unplugged: #expect(!car.pluggedIn)
            case .car: #expect(home.loadpoints.level(car)?.origin == .car)
            case .carOld: #expect(home.loadpoints.level(car)?.origin == .carEarlier)
            case .assumed: #expect(home.loadpoints.level(car)?.origin == .assumed)
            case .estimated, .late: #expect(home.loadpoints.level(car)?.origin == .estimated)
            case .noGoal: #expect(car.schedule == nil)
            case .charging: #expect(car.manualActive)
            }
        }
    }
}

extension LoadpointsModel {
    @MainActor
    func saveGoalAndWait(_ lp: Loadpoint, _ rig: CarFlowTests.Rig, socPct: Double, clock: Int, recurring: Bool, days: Int) async {
        let task = Task { await saveGoal(lp, socPct: socPct, clock: clock, recurring: recurring, days: days, zone: zone) }
        await rig.run(1_500)
        await task.value
    }
}

/// Timers that fire in the reverse of the order they were set, as the live
/// scheduler's sleeping tasks may.
@MainActor
final class ReversingScheduler: Scheduler {
    var nowMs: Double = 0
    private var due: [@MainActor () -> Void] = []

    func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> Cancellable {
        due.append(action)
        return Cancellable()
    }

    func random() -> Double { 0.5 }

    func fireAll() {
        let now = due
        due = []
        for action in now.reversed() { action() }
    }
}

@MainActor
@Suite struct LoopbackTests {
    /// The demo's answers arrive in the order the box sent them, whatever
    /// order the timers fire in. Out of order, a chunk before its head read
    /// as "your box didn't answer".
    @Test func framesArriveInTheOrderTheyWereSent() {
        let scheduler = ReversingScheduler()
        let box = SimulatedBox(scheduler: ManualScheduler())
        let carrier = LoopbackCarrier(box: box, scheduler: scheduler)
        var got: [Bytes] = []
        carrier.setHandlers(onFrame: { got.append($0) }, onStatus: { _ in })
        scheduler.fireAll()
        let sent: [Bytes] = [[1], [2], [3]]
        for f in sent { box.send?(f) }
        scheduler.fireAll()
        #expect(got == sent)
    }
}
