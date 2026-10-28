import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire
import FTWDemo
import FTWShared

/// The days behind today: their own window, their own read, and how
/// History's price row reads one of them. The box is the record — a day it
/// has nothing for stays a hole.
@MainActor
@Suite struct PriceHistoryTests {
    let scheduler = ManualScheduler(nowMs: CarTextTests.t)
    let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-price-\(UUID().uuidString)"))
    let store = MemoryStore()

    func run(_ ms: Double, step: Double = 20) async {
        var left = ms
        while left > 0 {
            for _ in 0..<10 { await Task.yield() }
            scheduler.advance(min(step, left))
            left -= step
        }
        for _ in 0..<10 { await Task.yield() }
    }

    func site(files: SealedFiles? = nil) -> SiteModel {
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: files, shared: shared)
        site.start()
        return site
    }

    var clock: ZoneClock { .of(CarTextTests.stockholm) }
    var midnight: Double { clock.calendar.startOfDay(for: Date(timeIntervalSince1970: scheduler.nowMs / 1000)).timeIntervalSince1970 * 1000 }

    /// The screen ahead asks for nothing behind: the widgets' record still
    /// starts at today's midnight, and a day behind reads as a hole.
    @Test func withoutTheSecondReadThereIsNoPastAndNothingPretendsOtherwise() async throws {
        let site = self.site()
        let prices = PriceModel(site: site, calendar: clock.calendar)
        site.connect(LoopbackCarrier(box: SimulatedBox(scheduler: scheduler, house: SimulatedHouse(timeZone: CarTextTests.stockholm)), scheduler: scheduler))
        prices.activate()
        await run(2_000)

        let window = try #require(prices.window)
        #expect(window.value.fromMs == midnight)
        #expect(prices.past == nil)
        #expect(prices.slots(fromMs: midnight - 86_400_000, toMs: midnight).isEmpty)
        #expect(!prices.day(fromMs: midnight - 86_400_000, toMs: midnight, clock: clock).known)
        // Today is in the window ahead, so History's row has it at once.
        #expect(prices.day(fromMs: midnight, toMs: midnight + 86_400_000, clock: clock).known)

        // The widgets' record is untouched by any of this: today forward.
        let record = try #require(CacheReader(sources: [shared]).read(PriceEntry.self, siteId: "home"))
        #expect(record.value.fromMs == midnight)
        #expect(record.value.prices.slots.allSatisfy { $0.startMs >= midnight })
    }

    /// The second read lands the two days behind, on their own window, and
    /// the two series read as one with no seam at midnight.
    @Test func theDaysBehindComeInTheirOwnReadAndJoinTheDaysAhead() async throws {
        let site = self.site()
        let prices = PriceModel(site: site, calendar: clock.calendar)
        site.connect(LoopbackCarrier(box: SimulatedBox(scheduler: scheduler, house: SimulatedHouse(timeZone: CarTextTests.stockholm)), scheduler: scheduler))
        prices.activate()
        prices.activatePast()
        await run(3_000)

        let past = try #require(prices.past)
        #expect(past.value.fromMs == midnight - PriceModel.pastMs)
        #expect(past.origin == .relay)
        #expect(past.value.prices.slots.allSatisfy { $0.startMs < midnight })

        // Two days behind, today and tomorrow, as one series with no hole.
        let from = midnight - PriceModel.pastMs
        let slots = prices.slots(fromMs: from, toMs: midnight + 86_400_000)
        #expect(slots.count == 3 * 96)
        #expect(slots.first?.startMs == from)
        #expect(Set(slots.map(\.startMs)).count == slots.count)
        for i in slots.indices.dropFirst() {
            #expect(slots[i - 1].startMs + slots[i - 1].durationMs == slots[i].startMs)
        }

        // The row reads each day behind on its own.
        for back in 1...2 {
            let day = prices.day(fromMs: midnight - Double(back) * 86_400_000, toMs: midnight - Double(back - 1) * 86_400_000, clock: clock)
            #expect(day.known, "day \(back) back")
            #expect(day.covered == 1)
            #expect(day.bars.count == 96)
            #expect(day.note == nil)
        }
    }

    /// One read a day. The days behind do not change when tomorrow's rates
    /// publish, so nothing asks again until the day turns.
    @Test func thePastIsAskedOnceADay() async throws {
        let site = self.site()
        let prices = PriceModel(site: site, calendar: clock.calendar)
        let box = SimulatedBox(scheduler: scheduler, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
        site.connect(LoopbackCarrier(box: box, scheduler: scheduler))
        // The day the test starts on: every window that begins before it
        // is a window behind, whatever the clock has moved on to.
        let today = midnight
        func asked() -> Int { box.priceWindows.filter { $0.lowerBound < today }.count }
        prices.activate()
        prices.activatePast()
        await run(3_000)
        #expect(asked() == 1)

        // The hour tomorrow's rates publish moves the window ahead, never
        // the one behind.
        await run(4 * 3_600_000, step: 60_000)
        #expect(asked() == 1)
        #expect(prices.past != nil)

        // A screen that leaves and comes back asks nothing new.
        prices.deactivatePast()
        prices.activatePast()
        await run(2_000)
        #expect(asked() == 1)

        // The day turning does: the window behind is a new one.
        await run(12 * 3_600_000, step: 60_000)
        #expect(asked() == 2)
    }

    /// A price window crosses the session, not the API, so its failures are
    /// the session's. With no window behind, the screen says what happens
    /// now rather than reading as a market that said nothing.
    @Test func aFailedReadSaysSoRatherThanReadingAsNoPrices() async throws {
        let site = self.site()
        let prices = PriceModel(site: site, calendar: clock.calendar)
        let box = SimulatedBox(scheduler: scheduler, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
        site.connect(LoopbackCarrier(box: box, scheduler: scheduler))
        prices.activate()
        await run(2_000)
        #expect(prices.pastProblem == nil)

        // The box hears the window and never answers it.
        box.answersPrices = false
        prices.activatePast()
        await run(Session.priceTimeoutMs + 2_000, step: 1_000)
        #expect(prices.past == nil)
        #expect(prices.pastProblem == "No prices yet. Your box is out of reach.")

        // Once it answers, the sentence goes.
        box.answersPrices = true
        await run(60_000, step: 1_000)
        #expect(prices.past != nil)
        #expect(prices.pastProblem == nil)
    }

    /// The days behind are kept on this phone, in their own file, so
    /// History's price row paints in frame one after a kill.
    @Test func theDaysBehindArePaintedFromThePhoneOnTheNextLaunch() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-price-past-\(UUID().uuidString)")
        let files = SealedFiles(directory: directory, store: store)
        let first = site(files: files)
        let prices = PriceModel(site: first, calendar: clock.calendar)
        first.connect(LoopbackCarrier(box: SimulatedBox(scheduler: scheduler, house: SimulatedHouse(timeZone: CarTextTests.stockholm)), scheduler: scheduler))
        prices.activate()
        prices.activatePast()
        await run(3_000)
        #expect(prices.past != nil)
        first.persistNow(wait: true)

        // A second launch, nothing on the wire.
        let next = site(files: SealedFiles(directory: directory, store: store))
        let opened = PriceModel(site: next, calendar: clock.calendar)
        let kept = try #require(opened.past)
        #expect(kept.origin == .cache)
        #expect(kept.value.fromMs == midnight - PriceModel.pastMs)
        #expect(opened.day(fromMs: midnight - 86_400_000, toMs: midnight, clock: clock).known)
    }
}
