import Foundation
import Testing
@testable import FTWKit
@testable import FTWDemo
import FTWShared

/// Today over the grid, from the box to the App Group: the demo box's
/// `savings/daily` and history, read by `GridTodayShare` as on a real box,
/// and left as the record the grid widget draws.
@MainActor
@Suite struct GridTodayShareTests {
    static let stockholm = TimeZone(identifier: "Europe/Stockholm")!

    func shared() -> AppGroupFiles {
        AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-grid-\(UUID().uuidString)"))
    }

    /// 13 October 2026 at 17:30 in Stockholm.
    static let evening: Double = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = stockholm
        return c.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 17, minute: 30))!.timeIntervalSince1970 * 1000
    }()

    /// The demo as a Debug build photographs it: it leaves its records for
    /// the widgets under the home "demo".
    func demo(nowMs: Double = evening, sunny: Bool = false, shares: Bool = true, files: AppGroupFiles) async -> (AppModel, HomeModels, ManualScheduler) {
        let scheduler = ManualScheduler(nowMs: nowMs)
        let app = AppModel(store: MemoryStore(), files: nil, shared: files, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { s in
            let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: Self.stockholm))
            box.house.sunny = sunny
            return LoopbackCarrier(box: box, scheduler: s)
        })
        app.demoSharesWidgets = shares
        app.startDemo()
        let home = app.home!
        await run(scheduler, 3_000)
        return (app, home, scheduler)
    }

    func run(_ s: ManualScheduler, _ ms: Double, step: Double = 50) async {
        var left = ms
        while left > 0 {
            for _ in 0..<10 { await Task.yield() }
            s.advance(min(step, left))
            left -= step
        }
        for _ in 0..<10 { await Task.yield() }
    }

    func record(_ files: AppGroupFiles) async -> CacheRecord<GridTodayEntry>? {
        // The write runs off the main actor.
        for _ in 0..<200 {
            if let r = files.read(GridTodayEntry.self, siteId: "demo") { return r }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func theDemoFillsEveryPartOfTheWidget() async throws {
        let files = shared()
        let (_, home, s) = await demo(files: files)
        let r = try #require(await record(files))
        let e = r.value
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.stockholm
        #expect(e.day == "2026-10-13")
        #expect(e.timeZone == "Europe/Stockholm")
        #expect(e.dayEndMs - e.dayStartMs == 24 * 3_600_000)
        #expect(e.importWh > 1_000 && e.exportWh > 0)
        #expect(e.costMinor != nil)
        #expect(e.pricedCoverage == 1)
        #expect(e.currency == "SEK")
        #expect(r.carrier == .relay)
        #expect(r.srcState == .live)
        #expect(r.readAtMs <= s.nowMs && r.readAtMs >= Self.evening)

        // The chart covers midnight to now, a quarter at a time, and none
        // of the evening still to come.
        #expect(e.quarters.count == 71)
        #expect(e.quarters.first?.startMs == e.dayStartMs)
        #expect(e.quarters.allSatisfy { $0.measured })
        #expect((e.quarters.last?.startMs ?? 0) <= s.nowMs)

        // The totals and the chart are one day: the quarters add up to what
        // the box counted, within the quarter still filling.
        let bought = e.quarters.reduce(0) { $0 + ($1.importW ?? 0) * 0.25 }
        let sold = e.quarters.reduce(0) { $0 + ($1.exportW ?? 0) * 0.25 }
        #expect(abs(bought - e.importWh) / e.importWh < 0.03, "\(bought) vs \(e.importWh)")
        #expect(abs(sold - e.exportWh) < 0.03 * e.exportWh + 50, "\(sold) vs \(e.exportWh)")

        // And the widget draws it all.
        let m = GridGlance.moment(CacheRead(record: r, origin: .app), atMs: s.nowMs, language: .sv)
        #expect(m.state == .today)
        #expect(m.netText != nil && m.inOutText != nil && m.costText != nil)
        #expect(m.costNote == nil)
        #expect(m.hasChart)
        #expect(m.samples.contains { ($0.value ?? 0) > 0 })
        #expect(m.timeText?.hasPrefix("kl ") == true)
        // An October evening buys more than it sells.
        #expect(m.direction == .fromGrid)
        _ = home
    }

    /// `-FTWDemoSunny YES`: a long clear day that sells more than it buys,
    /// so the word says sold and the cost is money earned.
    @Test func aSunnyDemoDayIsANetExportDay() async throws {
        let files = shared()
        _ = await demo(sunny: true, files: files)
        let r = try #require(await record(files))
        #expect(r.value.exportWh > r.value.importWh)
        let m = GridGlance.moment(CacheRead(record: r, origin: .app), atMs: r.readAtMs, language: .sv)
        #expect(m.direction == .toGrid)
        #expect(m.earned)
        #expect(m.costText?.hasPrefix("−") == true)
        #expect(m.netWord == "sålt netto")
        // Selling under zero and buying over it: the scale has both sides.
        let series = m.series(size: CGSize(width: 300, height: 80))
        #expect(series.domain.lower < 0 && series.domain.upper > 0)
    }

    @Test func aPartlyPricedDemoDayIsMarked() async throws {
        let files = shared()
        let scheduler = ManualScheduler(nowMs: Self.evening)
        let app = AppModel(store: MemoryStore(), files: nil, shared: files, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { s in
            let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: Self.stockholm))
            box.pricedShare = 0.8
            return LoopbackCarrier(box: box, scheduler: s)
        })
        app.demoSharesWidgets = true
        app.startDemo()
        await run(scheduler, 3_000)
        let r = try #require(await record(files))
        #expect(r.value.pricedCoverage == 0.8)
        #expect(GridGlance.moment(CacheRead(record: r, origin: .app), atMs: r.readAtMs, language: .en).costNote == "partial")
    }

    /// Without the Debug switch the demo still writes nothing a widget
    /// could take for a home.
    @Test func theDemoAloneLeavesNoGridRecord() async {
        let files = shared()
        _ = await demo(shares: false, files: files)
        #expect(files.siteIDs(GridTodayEntry.self).isEmpty)
        #expect(files.siteIDs(PriceEntry.self).isEmpty)
    }

    /// Once a quarter hour while the app is on screen, and not at all while
    /// it is hidden.
    @Test func itReadsEachQuarterHourOnlyWhileOnScreen() async throws {
        let files = shared()
        let (_, home, s) = await demo(files: files)
        let first = try #require(await record(files))
        // Within the quarter: nothing new.
        await run(s, 5 * 60_000, step: 1_000)
        #expect(files.read(GridTodayEntry.self, siteId: "demo")?.readAtMs == first.readAtMs)
        // Past 17:45 the next quarter is read.
        await run(s, 11 * 60_000, step: 1_000)
        try? await Task.sleep(for: .milliseconds(50))
        let second = try #require(files.read(GridTodayEntry.self, siteId: "demo"))
        #expect(second.readAtMs > first.readAtMs)
        #expect(second.value.quarters.count > first.value.quarters.count)

        // Hidden, the app asks nothing.
        home.site.setVisible(false)
        await run(s, 16 * 60_000, step: 1_000)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(files.read(GridTodayEntry.self, siteId: "demo")?.readAtMs == second.readAtMs)
    }

    /// The box's row as it answers it. The cost is `actual_cost_ore`, never
    /// one this app worked out.
    @Test func theTotalsAreTheBoxsOwn() throws {
        let row: JSON = ["day": "2026-10-13", "import_wh": 6_512.4, "export_wh": 8_301, "import_cost_ore": 900, "export_revenue_ore": 1_320,
                         "actual_cost_ore": -420, "priced_coverage_pct": 0.97, "resolution": "slot"]
        let t = try #require(GridTodayShare.totals(row))
        #expect(t.day == "2026-10-13")
        #expect(t.importWh == 6_512 && t.exportWh == 8_301)
        #expect(t.costMinor == -420)
        #expect(t.pricedCoverage == 0.97)

        let unpriced: JSON = ["day": "2026-10-13", "import_wh": 6_500, "export_wh": 0, "actual_cost_ore": 0, "priced_coverage_pct": 0, "resolution": "no_prices"]
        #expect(try #require(GridTodayShare.totals(unpriced)).costMinor == nil)
        // A counter fault is not energy, and a share over one is one.
        let odd: JSON = ["day": "2026-10-13", "import_wh": -5, "priced_coverage_pct": 1.4]
        let o = try #require(GridTodayShare.totals(odd))
        #expect(o.importWh == 0 && o.exportWh == 0)
        #expect(o.pricedCoverage == 1)
        #expect(o.costMinor == nil)
        #expect(GridTodayShare.totals(["import_wh": 1]) == nil)
    }

    /// The grid widget draws the grid in the app's own grid role, magenta
    /// both ways, from the shared catalog: no colour of its own and no
    /// other energy's hue.
    @Test func theWidgetDrawsTheGridInTheGridRole() throws {
        let source = try RepoFiles.read("appleApp/FTWWidgets/GridToday/GridTodayViews.swift")
        #expect(source.contains("Theme.grid"))
        for other in ["solar", "gives", "stores", "car", "live", "alarm"] {
            #expect(!source.contains("Theme.\(other)"), "the grid widget uses \(other)")
        }
        _ = try RepoFiles.read("appleApp/FTWCharts/Theme.xcassets/ftw.grid.colorset/Contents.json")
    }
}
