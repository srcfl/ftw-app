import Foundation
import Testing
@testable import FTWShared

/// When the app asks iOS to wake it for tomorrow's prices.
@Suite struct PriceRefreshTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!.timeIntervalSince1970 * 1000
    }

    @Test func beforeTheMarketPublishesItWaitsForFivePastOne() {
        #expect(PriceRefresh.next(afterMs: at(12, 8), pricesEndMs: at(13, 0), calendar: calendar) == at(12, 13, 5))
    }

    @Test func withTomorrowInHandTheNextIsTomorrows() {
        #expect(PriceRefresh.next(afterMs: at(12, 13, 20), pricesEndMs: at(14, 0), calendar: calendar) == at(13, 13, 5))
    }

    /// The box asks the market once an hour, so at 13:05 it may not have
    /// tomorrow yet. Ask again in half an hour, until the evening.
    @Test func withoutTomorrowItAsksAgainSoon() {
        #expect(PriceRefresh.next(afterMs: at(12, 13, 10), pricesEndMs: at(13, 0), calendar: calendar) == at(12, 13, 40))
        #expect(PriceRefresh.next(afterMs: at(12, 13, 10), pricesEndMs: nil, calendar: calendar) == at(12, 13, 40))
        #expect(PriceRefresh.next(afterMs: at(12, 19, 50), pricesEndMs: at(13, 0), calendar: calendar) == at(13, 13, 5))
    }

    /// 13:05 on the household's clock, also across the night the clocks go
    /// back.
    @Test func fivePastOneIsWallClockAcrossTheClockChange() {
        let next = PriceRefresh.next(afterMs: at(24, 14), pricesEndMs: at(26, 0), calendar: calendar)
        #expect(next == at(25, 13, 5))
        #expect(next - at(24, 13, 5) == 25 * 3_600_000)
    }
}
