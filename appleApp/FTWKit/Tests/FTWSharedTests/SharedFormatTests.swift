import Foundation
import Testing
@testable import FTWShared

/// The formatters a widget needs, pinned to the web app's own cases. These
/// read English: the tests run in the development language.
@Suite struct SharedFormatTests {
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

    @Test func theBandMatchesTheWebAppsCases() {
        func band(_ carrier: CarrierKind, transport: CarrierKind = .none, _ src: SourceState, age: Double?, _ phase: SessionPhase, wait: Double = 0, boot: Int? = nil, noCarrier: Bool = false) -> Freshness.Band {
            Freshness.band(carrier: carrier, transport: transport, srcState: src, ageMs: age, phase: phase, waitMs: wait, bootPct: boot, noCarrier: noCarrier)
        }
        // A decision about the phone is not a connection fault.
        let ended = band(.none, .stale, age: 7_200_000, .terminated)
        #expect(ended.message == "Access ended")
        // No carrier at all: no promise of a retry.
        let lost = band(.none, .stale, age: 60_000, .failed, noCarrier: true)
        #expect(lost.message == "Can't reach your box")
        #expect(lost.tone == .lost)
        #expect(lost.wait == nil)
        // A carrier healing itself says so, with its elapsed time.
        let healing = band(.none, .stale, age: 60_000, .failed, wait: 7_000)
        #expect(healing.message == "Reconnecting to your box")
        #expect(healing.wait == "7s")
        #expect(healing.age == "1 min ago")
        // Live only for live readings.
        let quiet = band(.relay, .stale, age: 5_000, .streaming)
        #expect(quiet.message == "Encrypted relay connected · readings")
        #expect(quiet.tone == .stale)
        #expect(!quiet.message.lowercased().contains("live"))
        #expect(band(.relay, .live, age: 0, .streaming).message == "Live via encrypted relay")
        #expect(band(.relay, .live, age: 0, .streaming).age == nil)
        // A starting box shows its own progress.
        let booting = band(.none, transport: .relay, .stale, age: 5_000, .booting, boot: 40)
        #expect(booting.message == "Your box is starting")
        #expect(booting.wait == "40%")
        // After a restart the box cannot place the reading: a dash, never a guess.
        #expect(band(.cache, transport: .relay, .stale, age: nil, .handshaking).age == "—")
        #expect(band(.cache, transport: .relay, .stale, age: nil, .handshaking).message == "Securing encrypted relay")
    }

    /// A relay that turned this phone away is busy, not broken, and has no
    /// countdown: waiting longer does not help.
    @Test func aFullRelayIsBusy() {
        let busy = Freshness.band(carrier: .none, transport: .relay, srcState: .stale, ageMs: 60_000, phase: .failed, waitMs: 9_000, bootPct: nil, noCarrier: false, busy: true)
        #expect(busy.tone == .busy)
        #expect(busy.message == "FTW is busy")
        #expect(busy.wait == nil)
        #expect(busy.age == "1 min ago")
        // Once a carrier streams again, busy no longer applies.
        let live = Freshness.band(carrier: .relay, transport: .relay, srcState: .live, ageMs: 0, phase: .streaming, waitMs: 0, bootPct: nil, noCarrier: false, busy: true)
        #expect(live.tone == .live)
    }

    @Test func thePriceCardFindsTheCheapestTwoHoursAhead() {
        let hour = 3_600_000.0
        let day = 1_750_000_000_000.0
        let totals: [Double] = [100, 120, 40, 30, 35, 200, -5, 90]
        let slots = totals.enumerated().map { PriceSlot(startMs: day + Double($0.offset) * hour, durationMs: hour, spotMinor: $0.element, totalMinor: $0.element) }
        let prices = Prices(zone: "SE3", currency: "SEK", slots: slots, stale: false)
        let s = PriceStrip.summary(prices, nowMs: day + 1.5 * hour)
        #expect(s.current?.totalMinor == 120)
        // The slot already over is not ahead.
        #expect(s.bars.count == 7)
        #expect(s.bars.first?.current == true)
        #expect(s.bars.first(where: { $0.minor == -5 })?.tone == .negative)
        #expect(s.bars.first(where: { $0.minor == 200 })?.tone == .dear)
        #expect(s.bars.first(where: { $0.minor == 30 })?.tone == .cheap)
        // 30 then 35 beats 40 then 30: two whole hours in a row, the lowest mean.
        #expect(s.cheapest == PriceStrip.Block(meanMinor: 32.5, startMs: day + 3 * hour, endMs: day + 5 * hour))
        #expect(PriceStrip.text(144.4, "SEK") == "144")
        #expect(PriceStrip.text(14.44, "SEK") == "14.4")
        #expect(PriceStrip.text(nil, "SEK") == "—")
    }
}
