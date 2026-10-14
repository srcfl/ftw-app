import Foundation
import Testing
@testable import FTWShared

/// What the plan saves, said only where it compares honestly: the plan
/// ends about where it starts, there is a saving to speak of, and the
/// baseline is no battery at all.
@Suite struct PlanSavingTests {
    let zone = TimeZone(identifier: "Europe/Stockholm")!
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    func at(_ day: Int, _ hour: Int) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!.timeIntervalSince1970 * 1000
    }

    /// The home box on 14 Oct: 43.50 kr against 71.69 kr with no battery,
    /// full at both ends, to Thursday 24:00.
    @Test func theHomeBoxsPlanSays28Kronor() {
        let s = PlanSaving(costMinor: 4_350.49, noBatteryMinor: 7_168.53, startLevel: 1, endLevel: 1, endMs: at(16, 0))
        #expect(s.savedMinor.map { ($0 / 100).rounded() } == 28)
        #expect(s.text(currency: "SEK", nowMs: at(14, 16), zone: zone) == "ABOUT 28 KR LESS THAN NO BATTERY · TO THU 24:00")
        // Within the day, no day is named.
        let soon = PlanSaving(costMinor: 4_350.49, noBatteryMinor: 7_168.53, startLevel: 1, endLevel: 1, endMs: at(14, 22))
        #expect(soon.text(currency: "EUR", nowMs: at(14, 16), zone: zone) == "ABOUT 28 € LESS THAN NO BATTERY · TO 22:00")
    }

    /// A plan that ends emptier has spent stored energy; the plain
    /// difference would flatter it, so nothing is said.
    @Test func aPlanThatEndsEmptierSaysNothing() {
        #expect(PlanSaving(costMinor: 1_954, noBatteryMinor: 7_168, startLevel: 1, endLevel: 0.32, endMs: at(16, 0)).savedMinor == nil)
        #expect(PlanSaving(costMinor: 4_350, noBatteryMinor: 7_168, startLevel: 0.5, endLevel: 0.55, endMs: at(16, 0)).savedMinor != nil)
        #expect(PlanSaving(costMinor: 4_350, noBatteryMinor: 7_168, startLevel: 0.5, endLevel: 0.56, endMs: at(16, 0)).savedMinor == nil)
    }

    @Test func noSavingToSpeakOfSaysNothing() {
        #expect(PlanSaving(costMinor: 7_100, noBatteryMinor: 7_168, startLevel: 1, endLevel: 1, endMs: at(16, 0)).savedMinor == nil)
        #expect(PlanSaving(costMinor: 8_000, noBatteryMinor: 7_168, startLevel: 1, endLevel: 1, endMs: at(16, 0)).savedMinor == nil)
        #expect(PlanSaving(costMinor: .nan, noBatteryMinor: 7_168, startLevel: 1, endLevel: 1, endMs: at(16, 0)).savedMinor == nil)
    }
}
