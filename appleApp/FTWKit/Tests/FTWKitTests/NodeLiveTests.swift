import Foundation
import FTWShared
import Testing
@testable import FTWKit

/// The words around a node's live trace: the status line, the footer, the
/// line under the chart and the hero's second fact.
@Suite struct NodeLiveTests {
    static let utc = TimeZone(identifier: "UTC")!

    /// One status line per screen: the title's speaks for the home, and the
    /// footer names the device and gives this node's age only when the title
    /// does not already give one. A clock time, never a count of seconds.
    @Test func theFooterNamesTheDeviceAndGivesTheAgeOnlyWhenThisNodeAloneIsNotLive() {
        AppWords.$language.withValue(.en) {
            let live = NodeFreshness(carrier: .relay, srcState: .live, ageMs: 400, sourceName: "sungrow")
            #expect(NodeLive.footer(.battery, live, carrier: .relay, periodMs: 1_000, titleSaysAge: false, nowMs: 50_000_000, zone: Self.utc) == "VIA RELAY · SUNGROW · READS EVERY 1 S")
            #expect(NodeLive.footer(.home, live, carrier: .relay, periodMs: 1_000, titleSaysAge: false, nowMs: 50_000_000, zone: Self.utc) == "VIA RELAY · CALCULATED · READS EVERY 1 S")
            // 13:53:20 less five minutes, while the rest of the home is live.
            let old = NodeFreshness(carrier: .relay, srcState: .stale, ageMs: 300_000, sourceName: "sungrow")
            let alone = NodeLive.footer(.battery, old, carrier: .relay, periodMs: 1_000, titleSaysAge: false, nowMs: 50_000_000, zone: Self.utc)
            #expect(alone == "○ AS OF 13:48 · VIA RELAY · SUNGROW")
            #expect(!alone.contains(" s") && !alone.contains("●"))
            // The whole home quiet: the title says so, the footer does not.
            #expect(NodeLive.footer(.battery, old, carrier: .cache, periodMs: nil, titleSaysAge: true, nowMs: 50_000_000, zone: Self.utc) == "SAVED ON THIS PHONE · SUNGROW")
            let never = NodeFreshness(carrier: .relay, srcState: .never, ageMs: nil, sourceName: nil)
            #expect(NodeLive.footer(.solar, never, carrier: .relay, periodMs: nil, titleSaysAge: false, nowMs: 0, zone: Self.utc) == "○ NO READING YET · VIA RELAY")
        }
        AppWords.$language.withValue(.sv) {
            let old = NodeFreshness(carrier: .relay, srcState: .stale, ageMs: 300_000, sourceName: "sungrow")
            #expect(NodeLive.footer(.battery, old, carrier: .relay, periodMs: 1_000, titleSaysAge: false, nowMs: 50_000_000, zone: Self.utc) == "○ PER 13:48 · VIA RELÄ · SUNGROW")
        }
    }

    /// A switch between the relay and FTW Cloud changes the footer's first
    /// word and nothing else.
    @Test func aSwitchOfPathChangesOnlyTheFootersFirstWord() {
        let f = NodeFreshness(carrier: .relay, srcState: .live, ageMs: 400, sourceName: "sungrow")
        func footer(_ carrier: CarrierKind, _ periodMs: Double?) -> String {
            NodeLive.footer(.battery, f, carrier: carrier, periodMs: periodMs, titleSaysAge: false, nowMs: 0, zone: Self.utc)
        }
        AppWords.$language.withValue(.en) {
            let relay = footer(.relay, 1_000)
            let cloud = footer(.cloud, 1_000)
            #expect(relay == "VIA RELAY · SUNGROW · READS EVERY 1 S")
            #expect(cloud == "VIA FTW CLOUD · SUNGROW · READS EVERY 1 S")
            #expect(relay.split(separator: "·").dropFirst() == cloud.split(separator: "·").dropFirst())
            #expect(footer(.relay, 5_200) == "VIA RELAY · SUNGROW · READS EVERY 5 S")
            #expect(footer(.cache, 1_000) == "SAVED ON THIS PHONE · SUNGROW")
        }
        AppWords.$language.withValue(.sv) {
            #expect(footer(.cloud, 60_000) == "VIA FTW CLOUD · SUNGROW · LÄSER VAR 60 S")
        }
    }

    /// The box's name for the device, in caps, never with its id's marks.
    @Test func theDeviceReadsAsAName() {
        #expect(NodeLive.deviceName("sungrow") == "SUNGROW")
        #expect(NodeLive.deviceName("sungrow_sh10-rt") == "SUNGROW SH10 RT")
        #expect(NodeLive.deviceName("") == nil)
        #expect(NodeLive.deviceName(nil) == nil)
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

    /// The sun's second fact is never empty while the box has a forecast:
    /// what the rest of today should bring while it shines, and when it
    /// comes back while it is down.
    @Test func theSunSaysWhatTheRestOfTodayBringsOrWhenItRises() {
        // Quarters from 00:00 UTC on 2 January 2026: dark until 07:45, then
        // 2 kW until 15:00, dark again, and up at 07:45 the next day.
        let day0 = 1_767_312_000_000.0
        let q = 900_000.0
        let slots = (0..<(4 * 36)).map { i -> PlanModel.Forecast in
            let hour = Double(i % 96) / 4
            return PlanModel.Forecast(startMs: day0 + Double(i) * q, durationMs: q, pvW: hour >= 7.75 && hour < 15 ? 2_000 : 0, loadW: 500, priceMinor: nil)
        }
        AppWords.$language.withValue(.en) {
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 5 * 3_600_000, zone: Self.utc) == "sun from about 07:45")
            // At noon, 2 kW for three more hours.
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 12 * 3_600_000, zone: Self.utc) == "6.0\u{00A0}kWh expected")
            // In the evening the next rise is tomorrow's.
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 20 * 3_600_000, zone: Self.utc) == "sun from about 07:45")
            // Nearly gone: the last quarter's 25 Wh is not worth a line.
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 14.99 * 3_600_000, zone: Self.utc) == "sun from about 07:45")
            #expect(NodeLive.solarOutlook([], nowMs: day0, zone: Self.utc) == nil)
            // A plan made this minute starts a few seconds after the minute.
            let late = slots.map { PlanModel.Forecast(startMs: $0.startMs + 20_000, durationMs: $0.durationMs, pvW: $0.pvW, loadW: $0.loadW, priceMinor: nil) }
            #expect(NodeLive.solarOutlook(late, nowMs: day0 + 12 * 3_600_000, zone: Self.utc)?.hasSuffix("kWh expected") == true)
            // One that starts hours from now says nothing of the sun now.
            #expect(NodeLive.solarOutlook(Array(slots.dropFirst(60)), nowMs: day0 + 5 * 3_600_000, zone: Self.utc) == nil)
        }
        AppWords.$language.withValue(.sv) {
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 5 * 3_600_000, zone: Self.utc) == "sol från cirka 07:45")
            #expect(NodeLive.solarOutlook(slots, nowMs: day0 + 12 * 3_600_000, zone: Self.utc) == "6,0\u{00A0}kWh väntas")
        }
    }

    /// Two fingers on the live trace: the hero shortens its words, never
    /// its type.
    @Test func aSpanOnTheTraceSaysItsMinutesAndMeanInShortWords() {
        let t = 1_767_312_000_000.0 + (5 * 3_600 + 44 * 60 + 16) * 1_000
        AppWords.$language.withValue(.en) {
            #expect(NodeLive.spanWords(fromMs: t, toMs: t + 3 * 60_000, meanW: -437, zone: Self.utc) == "05:44–05:47 · avg 437\u{00A0}W")
            #expect(NodeLive.spanWords(fromMs: t, toMs: t + 20_000, meanW: 437, zone: Self.utc) == "05:44 · avg 437\u{00A0}W")
        }
        AppWords.$language.withValue(.sv) {
            #expect(NodeLive.spanWords(fromMs: t, toMs: t + 3 * 60_000, meanW: 437, zone: Self.utc) == "05:44–05:47 · snitt 437\u{00A0}W")
        }
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
