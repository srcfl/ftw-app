import Foundation
import FTWShared
import Testing
@testable import FTWKit

/// The words around a node's live trace: the status line, the footer, the
/// line under the chart and the hero's second fact.
@Suite struct NodeLiveTests {
    static let utc = TimeZone(identifier: "UTC")!

    @Test func theStatusLineSaysLiveOrTheClockTimeNeverSeconds() {
        AppWords.$language.withValue(.en) {
            let live = NodeFreshness(carrier: .relay, srcState: .live, ageMs: 400, sourceName: "sungrow")
            #expect(NodeLive.status(.battery, live, nowMs: 50_000_000, zone: Self.utc) == "● LIVE · SUNGROW")
            #expect(NodeLive.status(.home, live, nowMs: 50_000_000, zone: Self.utc) == "● LIVE · CALCULATED")
            // 13:53:20 less five minutes: a clock time, not "5 min ago".
            let old = NodeFreshness(carrier: .cache, srcState: .stale, ageMs: 300_000, sourceName: "sungrow")
            #expect(NodeLive.status(.battery, old, nowMs: 50_000_000, zone: Self.utc) == "○ AS OF 13:48 · SUNGROW")
            let never = NodeFreshness(carrier: .relay, srcState: .never, ageMs: nil, sourceName: nil)
            #expect(NodeLive.status(.solar, never, nowMs: 0, zone: Self.utc) == "○ NO READING YET")
            #expect(!NodeLive.status(.battery, old, nowMs: 50_000_000, zone: Self.utc).contains(" s"))
        }
    }

    /// A switch between the relay and FTW Cloud changes the footer's first
    /// word and nothing else.
    @Test func aSwitchOfPathChangesOnlyTheFootersFirstWord() {
        AppWords.$language.withValue(.en) {
            let relay = NodeLive.footer(.relay, periodMs: 1_000)
            let cloud = NodeLive.footer(.cloud, periodMs: 1_000)
            #expect(relay == "VIA RELAY · READS EVERY 1 S")
            #expect(cloud == "VIA FTW CLOUD · READS EVERY 1 S")
            #expect(relay.split(separator: "·").dropFirst() == cloud.split(separator: "·").dropFirst())
            #expect(NodeLive.footer(.relay, periodMs: 5_200) == "VIA RELAY · READS EVERY 5 S")
            #expect(NodeLive.footer(.cache, periodMs: 1_000) == "SAVED ON THIS PHONE")
        }
        AppWords.$language.withValue(.sv) {
            #expect(NodeLive.footer(.cloud, periodMs: 60_000) == "VIA FTW CLOUD · LÄSER VAR 60 S")
        }
    }

    @Test func theRangeLineCountsEnergyAcrossJoinedSpansAndNotAcrossABreak() {
        // 1 kW for 6 minutes as two runs with a 2-minute break: 4 minutes count.
        let runs = [
            [LiveSample(t: 0, v: 1_000), LiveSample(t: 120_000, v: 1_000)],
            [LiveSample(t: 240_000, v: 1_000), LiveSample(t: 360_000, v: 1_000)],
        ]
        let e = NodeLive.energy(runs)
        #expect(abs(e.inWh - 1_000 * 4 / 60) < 1e-9 && e.outWh == 0)
        let half = NodeLive.energy(runs, untilMs: 60_000)
        #expect(abs(half.inWh - 1_000 / 60) < 1e-9)
        // Out of the site counts as out.
        let out = NodeLive.energy([[LiveSample(t: 0, v: -2_000), LiveSample(t: 60_000, v: -2_000)]])
        #expect(out.inWh == 0 && abs(out.outWh - 2_000 / 60) < 1e-9)
        AppWords.$language.withValue(.en) {
            #expect(NodeLive.range(.battery, (120, 50)) == "5 min: charged 120\u{00A0}Wh · gave 50\u{00A0}Wh")
            #expect(!NodeLive.range(.grid, (0, 50)).contains("-"))
        }
    }

    @Test func theHerosSecondFact() {
        AppWords.$language.withValue(.en) {
            // 1.5 kW at 196 öre/kWh: 2.94 kr an hour.
            #expect(NodeLive.gridCost(watts: 1_500, priceMinor: 196, currency: "SEK") == "≈ 2.94 kr/h")
            #expect(NodeLive.gridCost(watts: -1_000, priceMinor: 80, currency: "SEK") == "earns ≈ 0.80 kr/h")
            #expect(NodeLive.gridCost(watts: 10, priceMinor: 80, currency: "SEK") == nil)
            #expect(NodeLive.solarShare(madeW: 2_460, forecastW: 3_000) == "82 % of forecast" || NodeLive.solarShare(madeW: 2_460, forecastW: 3_000) == "82\u{00A0}% of forecast")
            #expect(NodeLive.solarShare(madeW: 50, forecastW: 60) == nil)
        }
        let shares = NodeLive.homeShares(pvW: -2_000, batteryW: -1_000, gridW: 1_000)
        #expect(shares?.sun == 0.5 && shares?.battery == 0.25 && shares?.grid == 0.25)
        // Charging the battery and selling take nothing from the home's share.
        let sunOnly = NodeLive.homeShares(pvW: -4_000, batteryW: 1_000, gridW: -2_000)
        #expect(sunOnly?.sun == 1)
    }

    @Test func aChipAddsOrTakesAwayASeriesAndTheLastOneStays() {
        var series = SeriesPick.read(nil, own: .battery)
        #expect(series == [.battery])
        series = SeriesPick.toggled(series, .grid, own: .battery)
        series = SeriesPick.toggled(series, .solar, own: .battery)
        // The node's own series first, the rest in Now's order.
        #expect(series == [.battery, .solar, .grid])
        series = SeriesPick.toggled(series, .battery, own: .battery)
        #expect(series == [.solar, .grid])
        series = SeriesPick.toggled(series, .solar, own: .battery)
        #expect(SeriesPick.toggled(series, .grid, own: .battery) == [.grid])
        #expect(SeriesPick.read("grid,bogus,home", own: .battery) == [.home, .grid])
        #expect(SeriesPick.read("", own: .solar) == [.solar])
    }

    @Test func everyNewWordHasSwedish() {
        for key in ["LIVE", "CALCULATED", "NO READING YET", "AS OF %@", "VIA RELAY", "VIA FTW CLOUD", "READS EVERY %@ S", "LIVE · LAST 5 MIN", "5 min: made %@", "earns ≈ %@", "%@ of forecast"] {
            #expect(NodeWords.sv[key] != nil, "\(key)")
        }
    }
}
