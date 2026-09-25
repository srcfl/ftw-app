import Foundation
import Testing
@testable import FTWKit

/// The sentences and figures the web app's own tests pin, so both apps say
/// the same thing about the same house.
@Suite struct FormatTests {
    typealias F = Contract.FID

    @Test func powerNeverShowsARawMinus() {
        for w in [-1_000_000.0, -4200, -60, 0, 60, 4200] {
            #expect(!PowerFormat.parts(w).text.hasPrefix("-"))
        }
        #expect(PowerFormat.parts(4200).direction == .into)
        #expect(PowerFormat.parts(-4200).direction == .out)
        #expect(PowerFormat.direction(PowerFormat.noiseW - 1) == .idle)
        #expect(PowerFormat.direction(-PowerFormat.noiseW) == .out)
        #expect(PowerFormat.parts(9900).text == "9.9")
        #expect(PowerFormat.parts(11_400).text == "11")
        #expect(PowerFormat.scale(5000) == "5 kW")
        #expect(PowerFormat.scale(1500) == "1.5 kW")
        #expect(PowerFormat.scale(-5000) == PowerFormat.scale(5000))
        #expect(PowerFormat.scale(.nan) == "")
        #expect(PowerFormat.soc(875) == "88")
        #expect(PowerFormat.soc(.nan) == "—")
        #expect(PowerFormat.age(0) == "just now")
        #expect(PowerFormat.age(30_000) == "30s ago")
        #expect(PowerFormat.age(90_000) == "1 min ago")
        #expect(PowerFormat.age(3_600_000) == "1 h ago")
        #expect(PowerFormat.age(nil) == "unknown")
    }

    @Test func explanationsMatchTheWebApp() {
        func explain(_ f: [Int: Double], blocked: [String] = [], ceiling: Double? = nil) -> Explanation.Result {
            Explanation.explain(fields: f, dispatchBlockedBy: blocked, ceilingW: ceiling)
        }
        let shaving = explain([F.gridW: 11_000, F.pvW: 0, F.batteryW: -4200, F.loadW: 15_200], ceiling: 11_000)
        #expect(shaving.situation == .batteryShaving)
        #expect(shaving.headline == "The battery is supplying 4.2 kW to keep grid import below 11 kW.")
        let covering = explain([F.gridW: 0, F.pvW: 0, F.batteryW: -2100, F.loadW: 2100])
        #expect(covering.headline == "The battery is covering the house, so nothing is coming from the grid.")
        let importing = explain([F.gridW: 2400, F.pvW: 0, F.batteryW: 0, F.loadW: 2400])
        #expect(importing.headline == "The house is drawing 2.4 kW from the grid.")
        #expect(explain([F.gridW: -3000, F.pvW: -5000, F.batteryW: 0, F.loadW: 2000]).situation == .exportingSurplus)
        #expect(explain([F.gridW: 0, F.pvW: -5000, F.batteryW: 3000, F.loadW: 2000]).situation == .chargingFromSurplus)
        #expect(explain([F.gridW: 10, F.pvW: -2000, F.batteryW: 0, F.loadW: 2000]).situation == .solarCovering)
        #expect(explain([F.gridW: 800, F.pvW: -1200, F.batteryW: 0, F.loadW: 2000]).situation == .solarPartial)
        #expect(explain([F.gridW: 2400, F.loadW: 2400], blocked: ["meter"]).situation == .dispatchBlocked)
        #expect(explain([:]).situation == .noData)
        #expect(!explain([F.gridW: -3000, F.pvW: -5000, F.batteryW: -100, F.loadW: 2000]).headline.contains("-"))
    }

    @Test func planHeadlineNamesTheNextChange() {
        let now = 1_750_000_000_000.0
        let slots = [
            PlanSlot(startMs: now - 60_000, durationMs: 900_000, batteryW: 3000, gridW: 3000, priceMinor: 30, reason: "cheap_import"),
            PlanSlot(startMs: now + 840_000, durationMs: 900_000, batteryW: 3000, gridW: 3000, priceMinor: 30, reason: "cheap_import"),
            PlanSlot(startMs: now + 1_740_000, durationMs: 900_000, batteryW: -2000, gridW: 0, priceMinor: 150, reason: "expensive_import"),
        ]
        let h = PlanText.headline(Plan(rev: 1, uptimeMs: 0, slots: slots, stale: false, ceilingW: nil), nowMs: now)
        #expect(h.text == "The battery is charging at 3.0 kW — power is cheap. Then it covers the house at 2.0 kW in about half an hour.")
        #expect(PlanText.headline(nil, nowMs: now).text == "No plan yet.")
        #expect(PlanText.headline(Plan(rev: 1, uptimeMs: 0, slots: [], stale: true, ceilingW: nil), nowMs: now).text.hasPrefix("Your box couldn't plan ahead"))
    }

    @Test func pricesInTheChartsUnit() {
        #expect(PriceUnits.text(144, "SEK") == "144.0")
        #expect(PriceUnits.unit("EUR").perKwh == "cent/kWh")
        #expect(PriceUnits.text(400, "CZK") == "4.00")
        #expect(PriceUnits.unit("XYZ").perKwh == "XYZ/kWh")
        let day: Double = 1_750_000_000_000
        let slots = [PriceSlot(startMs: day, durationMs: 3_600_000, spotMinor: 1, totalMinor: 1), PriceSlot(startMs: day + 7_200_000, durationMs: 3_600_000, spotMinor: 1, totalMinor: 1)]
        #expect(PriceUnits.hasHole(slots, fromMs: day))
        #expect(PriceUnits.hasHole(Array(slots.suffix(1)), fromMs: day))
        #expect(!PriceUnits.hasHole(Array(slots.prefix(1)), fromMs: day))
    }

    @Test func savingsAreSignedMajorUnits() {
        #expect(Savings.compact(1240) == "+12.4")
        #expect(Savings.compact(-310) == "−3.10")
        #expect(Savings.compact(12_345) == "+123")
        let days = (1...9).map { Savings.Day(day: String(format: "2026-09-%02d", $0), savedOre: 100, resolution: $0 == 9 ? "no_prices" : "slot") }
        let p = Savings.periods(days)
        #expect(!p.today.available)
        #expect(p.week.savedMinor == 600)
        #expect(!p.week.complete)
    }

    @Test func evSentencesSayOnlyWhatTheBoxSaid() throws {
        let unplugged = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":false,"current_soc":0.5}"#.utf8)))
        #expect(EVText.status(unplugged) == "Not plugged in")
        #expect(unplugged.socPct == nil)

        let charging = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"current_power_w":7200,"current_soc":0.41,"delivered_wh_session":3040}"#.utf8)))
        #expect(EVText.status(charging) == "Charging at 7.2 kW")
        #expect(charging.socPct == 41)
        #expect(EVText.session(charging) == "3.0 kWh this session")

        let paused = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":0,"manual":{"state":"paused"}}"#.utf8)))
        #expect(EVText.isPaused(paused))
        #expect(EVText.status(paused).hasPrefix("Paused by you."))

        let stale = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"charger":{"known":true,"available":false}}"#.utf8)))
        #expect(EVText.status(stale) == "Charger status is out of date. FTW cannot confirm whether the car is charging.")

        #expect(EVText.days(0) == "every day")
        #expect(EVText.days(0b0011111) == "weekdays")
        #expect(EVText.days(0b1100000) == "weekends")
        #expect(EVText.days(0b0000101) == "Mon, Wed")
    }

    @Test func chargeCurrentFallsBackLikeTheBoxPage() throws {
        let bare = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true}"#.utf8)))
        #expect(EVText.current(bare) == EVText.Current(minA: 6, maxA: 16, wattsPerAmp: 690, phases: 3))
        let capped = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"max_charge_w":11000,"min_charge_w":4140}"#.utf8)))
        // 16 A is 11 040 W, above the charger's ceiling: the ceiling wins.
        #expect(EVText.watts(capped, amps: 16) == 11_000)
        #expect(EVText.readout(capped, amps: 16) == "16 A · 11.0 kW")
    }

    @Test func scheduleClockConvertsThroughUTC() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let summer = Date(timeIntervalSince1970: 1_750_000_000)
        let utc = EVText.minuteUTC(hour: 7, minute: 0, at: summer, calendar: cal)
        #expect(utc == 5 * 60)
        let back = EVText.localTime(minuteUTC: 300, at: summer, calendar: cal)
        #expect(back.hour == 7 && back.minute == 0)
        #expect(EVText.minuteUTC(hour: 25, minute: 99, calendar: cal) == nil)
    }

    @Test func flowUsesMagnitudesAndDirections() {
        let r = Flow.readings(fields: [F.gridW: -1500, F.pvW: -4000, F.batteryW: 1200, F.batterySoc: 612, F.loadW: 1300])
        let grid = r.nodes.first { $0.role == .grid }!
        #expect(grid.kw == 1.5)
        #expect(!grid.toHub)
        #expect(grid.sub == "exporting")
        let battery = r.nodes.first { $0.role == .battery }!
        #expect(battery.sub == "charging")
        #expect(battery.socPct == 61)
        #expect(!r.nodes.contains { $0.role == .ev })
        let overlaid = Flow.withLoadpointEV([F.loadW: 9000, F.evW: 0], evW: 7400)
        #expect(overlaid[F.evW] == 7400)
        #expect(overlaid[F.loadW] == 1600)
    }
}
