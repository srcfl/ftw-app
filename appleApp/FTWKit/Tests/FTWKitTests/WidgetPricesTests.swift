import Foundation
import FTWDemo
import FTWShared
import Testing
@testable import FTWKit

/// The background refresh that leaves tomorrow's prices for the widgets.
@MainActor
@Suite struct WidgetPricesTests {
    let scheduler = ManualScheduler()
    let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-shared-\(UUID().uuidString)"))

    func site(wakes: Counter) -> SiteModel {
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: nil, shared: shared)
        site.sharedWritten = { wakes.count += 1 }
        site.start()
        return site
    }

    func run(_ ms: Double, step: Double = 20) async {
        var left = ms
        while left > 0 {
            for _ in 0..<10 { await Task.yield() }
            scheduler.advance(min(step, left))
            left -= step
        }
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aBackgroundRefreshLeavesPricesAndWakesTheWidgets() async throws {
        let wakes = Counter()
        let site = site(wakes: wakes)
        site.connect(SimulatedBox.loopback(scheduler))
        let asked = scheduler.nowMs
        let task = Task { await site.refreshSharedPrices() }
        await run(2_000)
        let written = try #require(await task.value)
        #expect(!written.slots.isEmpty)

        let read = try #require(CacheReader(sources: [shared]).read(PriceEntry.self, siteId: "home"))
        #expect(read.value.prices == written)
        #expect(read.carrier == .cache)
        #expect(read.record.readAtMs >= asked && read.record.readAtMs <= scheduler.nowMs)
        #expect(wakes.count == 1)
        #expect(site.sharedPricesEndMs == written.slots.map { $0.startMs + $0.durationMs }.max())
    }

    /// No stream, no write: the widgets keep what they had, and the task
    /// ends on time rather than holding the wake.
    @Test func withoutAStreamItGivesUpAndWritesNothing() async {
        let wakes = Counter()
        let site = site(wakes: wakes)
        let task = Task { await site.refreshSharedPrices(waitMs: 5_000) }
        await run(5_500, step: 250)
        #expect(await task.value == nil)
        #expect(shared.siteIDs(PriceEntry.self).isEmpty)
        #expect(wakes.count == 0)
        #expect(site.sharedPricesEndMs == nil)
    }
}
