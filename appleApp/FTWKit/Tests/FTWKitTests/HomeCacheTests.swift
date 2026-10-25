import Foundation
import Observation
import Synchronization
import Testing
@testable import FTWKit
import FTWDemo
@testable import FTWShared

/// Open on the last truth: after the app is killed, the next launch has the
/// plan, the prices, the mode label, Now's nodes and the car's watts before
/// the box has said hello; nothing kept unlocks a control; and the box
/// saying the same again changes nothing on screen.

// MARK: The stamp

@Suite struct StampedTests {
    @Test func theSameValueAgainChangesNothing() {
        let shown = Stamped(42, asOfMs: 1_000, origin: .relay)
        #expect(shown.taking(Stamped(42, asOfMs: 2_000, origin: .relay)) == nil)
        #expect(shown.taking(Stamped(42, asOfMs: 2_000, origin: .cloud)) == nil)
        // The box confirming what the cache said moves its origin and age.
        let kept = Stamped(42, asOfMs: 1_000, origin: .cache)
        #expect(kept.taking(Stamped(42, asOfMs: 2_000, origin: .relay)) == Stamped(42, asOfMs: 2_000, origin: .relay))
    }

    @Test func anOlderCopyNeverReplacesWhatTheBoxSaid() {
        let shown = Stamped(42, asOfMs: 2_000, origin: .relay)
        #expect(shown.taking(Stamped(41, asOfMs: 1_000, origin: .cloud)) == nil)
        #expect(shown.taking(Stamped(43, asOfMs: 3_000, origin: .cloud)) == Stamped(43, asOfMs: 3_000, origin: .cloud))
        // Anything the box says replaces the cache, however old the cache.
        let kept = Stamped(42, asOfMs: 5_000, origin: .cache)
        #expect(kept.taking(Stamped(40, asOfMs: 1_000, origin: .relay))?.value == 40)
        #expect(Stamped.taking(Stamped(1, asOfMs: 0, origin: .relay), over: nil)?.value == 1)
    }

    @Test func aStampReadBackIsTheCache() throws {
        let s = Stamped(PriceEntry(fromMs: 0, prices: Prices(zone: "SE3", currency: "SEK", slots: [], stale: false)), asOfMs: 7, origin: .cloud)
        let back = try JSONDecoder().decode(Stamped<PriceEntry>.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.cached.origin == .cache)
        #expect(back.cached.asOfMs == 7)
    }
}

// MARK: A home after a kill

/// One home on one phone across launches: the sealed files, the widgets'
/// files and a clock, with the demo box behind it.
@MainActor
final class KeptHome {
    let scheduler = ManualScheduler(nowMs: CarTextTests.t)
    let files = SealedFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-home-\(UUID().uuidString)"), store: MemoryStore())
    let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-home-shared-\(UUID().uuidString)"))

    /// A launch: the models of one home, started, not connected.
    func launch() -> HomeModels {
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: files, shared: shared)
        let home = HomeModels(site: site, cache: CacheReader(sources: [shared]))
        site.start()
        return home
    }

    /// What Now shows: the prices, the mode, the plan and the chargers.
    func look(_ home: HomeModels) {
        home.prices.activate()
        home.nodes.mode.activate()
        home.nodes.plan.activate(forecast: true)
        home.loadpoints.activate()
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

    /// A first launch that streams until everything Now shows has arrived,
    /// then goes to the background, where the app writes what it holds,
    /// and is killed.
    func liveThenKilled() async throws -> (home: HomeModels, nodes: [EnergyNode], car: NodeReading) {
        let home = launch()
        home.site.connect(SimulatedBox.loopback(scheduler))
        look(home)
        await run(3_000)
        #expect(home.site.heardFromBox)
        #expect(home.nodes.plan.stamped?.origin == .relay)
        let readings = NowFlow.readings(site: home.site, loadpoints: home.loadpoints)
        let car = try #require(readings.first { $0.node == .car })
        home.site.suspend()
        home.site.destroy()
        return (home, readings.map(\.node), car)
    }
}

@MainActor
@Suite struct HomeCacheTests {
    @Test func afterAKillEverythingNowShowsIsThereBeforeHello() async throws {
        let w = KeptHome()
        let (live, nodes, liveCar) = try await w.liveThenKilled()
        let label = try #require(live.nodes.mode.label)
        let plan = try #require(live.nodes.plan.plan)
        let prices = try #require(live.prices.prices)

        // Ten minutes later the app opens again, and nothing has connected.
        await w.run(10 * 60_000, step: 5_000)
        let cold = w.launch()
        #expect(!cold.site.heardFromBox)
        #expect(cold.site.session.phase == .idle)

        // The plan, dated, and never "no plan".
        #expect(cold.nodes.plan.plan == plan)
        #expect(cold.nodes.plan.stamped?.origin == .cache)
        let moment = cold.nodes.planShare.moment(nowMs: w.scheduler.nowMs)
        #expect(moment.state == .plan)
        #expect(moment.ageText != nil)
        #expect(!moment.events.isEmpty)
        #expect(moment.summary != PlanWord.noPlanYet.text)
        #expect(!moment.placeholder)

        // The prices, the forecast and the planner's style behind the label.
        #expect(cold.prices.prices == prices)
        #expect(cold.prices.window?.origin == .cache)
        #expect(!cold.nodes.plan.forecast.isEmpty)
        #expect(cold.nodes.mode.label == label)

        // Now's nodes, in their places, and the car at its last watts with
        // their age, never 0 W from nowhere.
        let readings = NowFlow.readings(site: cold.site, loadpoints: cold.loadpoints)
        #expect(readings.map(\.node) == nodes)
        let car = try #require(readings.first { $0.node == .car })
        #expect(car.watts == liveCar.watts)
        #expect(car.watts != nil)
        #expect(car.freshness.carrier == .cache)
        #expect(!car.freshness.live)
        #expect((car.freshness.ageMs ?? 0) >= 10 * 60_000)
        #expect(cold.loadpoints.points.first?.schedule != nil)
    }

    @Test func nothingKeptUnlocksAControlUntilTheBoxHasSpoken() async throws {
        let w = KeptHome()
        _ = try await w.liveThenKilled()
        let cold = w.launch()
        // The caps and the role are there, so the controls are drawn...
        #expect(cold.site.session.caps.contains(Contract.capPlanDispatch))
        #expect(cold.nodes.mode.mayControl)
        #expect(cold.site.canConfigure)
        // ...and none of them works.
        #expect(!cold.nodes.mode.canControl)
        #expect(!cold.site.heardFromBox)

        // A carrier that opens is not the box speaking.
        let box = ScriptedBox()
        cold.site.connect(box)
        box.open(w.scheduler.nowMs)
        await w.run(100)
        #expect(cold.site.session.phase == .handshaking)
        #expect(!cold.nodes.mode.canControl)
        #expect(cold.nodes.mode.label != nil)

        // Hello replaces what was kept, and only then does a control work.
        box.helloOk(uptimeMs: 60_000, cloud: nil, caps: [Contract.capPlanDispatch, Contract.capAPIPassthrough])
        await w.run(100)
        #expect(cold.site.heardFromBox)
        #expect(cold.nodes.mode.canControl)
    }

    /// Plan's mode row opens on the style the last launch kept, before the
    /// box has spoken, and stays inert. With nothing kept it has no word
    /// yet, never "Mode".
    @Test func plansModeRowOpensOnTheKeptStyle() async throws {
        let w = KeptHome()
        let fresh = w.launch()
        #expect(fresh.nodes.mode.label == nil)
        fresh.site.destroy()

        _ = try await w.liveThenKilled()
        let cold = w.launch()
        let style = try #require(cold.nodes.mode.shownStyle)
        #expect(cold.nodes.mode.label == "\(NodeWords.text("Plan")) · \(NodeWords.text(style.name))")
        #expect(!cold.nodes.mode.canControl)
        cold.site.destroy()

        // A home file with no style in it: no style until the box is asked,
        // and the box's answer that it gave none.
        var kept = try #require(w.files.readJSON(HomeCache.self, "home-home"))
        kept.prefs = nil
        w.files.writeJSON("home-home", kept)
        let bare = w.launch()
        #expect(bare.nodes.mode.shownStyle == nil)
        try? await bare.nodes.mode.loadPrefs()
        #expect(bare.nodes.mode.prefsMissing)
    }

    /// Hello names the box's uptime now. The cached readings were taken
    /// on the clock the cache kept, so their age does not move when hello
    /// lands before the first frame.
    @Test func helloDoesNotAgeTheCachedReadingsAgain() async throws {
        let w = KeptHome()
        _ = try await w.liveThenKilled()
        let keptUptime = try #require(w.files.readJSON(CachedSnapshot.self, "snapshot-home")?.uptimeMs)
        await w.run(10 * 60_000, step: 5_000)
        let cold = w.launch()
        let age = try #require(cold.site.ageMs)
        let battery = try #require(cold.site.freshness(.battery).ageMs)
        #expect(age >= 10 * 60_000)
        let box = ScriptedBox()
        cold.site.connect(box)
        box.open(w.scheduler.nowMs)
        // The box kept running while the app was away.
        box.helloOk(uptimeMs: Int64(keptUptime + 10 * 60_000 + 2_000), cloud: nil)
        await w.run(100)
        #expect(cold.site.heardFromBox)
        #expect(cold.site.carrier == .cache)
        #expect(abs((cold.site.ageMs ?? 0) - age) < 1_000)
        #expect(abs((cold.site.freshness(.battery).ageMs ?? 0) - battery) < 1_000)
    }

    @Test func anArrivalEqualToWhatIsShownChangesNothing() async throws {
        let w = KeptHome()
        let home = w.launch()
        home.site.connect(SimulatedBox.loopback(w.scheduler))
        w.look(home)
        await w.run(3_000)
        #expect(home.nodes.plan.stamped?.origin == .relay)
        #expect(home.prices.window?.origin == .relay)
        #expect(home.nodes.mode.prefsStamp?.origin == .relay)

        let confirmed = home.nodes.plan.receivedAtMs
        let changed = Mutex(false)
        withObservationTracking {
            _ = home.nodes.plan.stamped
            _ = home.prices.window
            _ = home.nodes.mode.prefsStamp
        } onChange: {
            changed.withLock { $0 = true }
        }
        // The box says it all again, the same.
        let asks = Task {
            try await home.nodes.plan.load()
            try await home.prices.load()
            try await home.nodes.mode.loadPrefs()
        }
        await w.run(1_000)
        try await asks.value
        #expect(!changed.withLock { $0 })
        // It still counts as the box confirming its plan, for the widget.
        #expect((home.nodes.plan.receivedAtMs ?? 0) > (confirmed ?? .infinity))
    }

    @Test func pricesAreKeptOverMidnight() async throws {
        let w = KeptHome()
        let (live, _, _) = try await w.liveThenKilled()
        let prices = try #require(live.prices.prices)
        // The next launch is after midnight. The box streams and has not
        // answered for the new day's prices yet.
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: w.scheduler.nowMs / 1000)).addingTimeInterval(86_400).timeIntervalSince1970 * 1000
        await w.run(midnight - w.scheduler.nowMs + 30 * 60_000, step: 60_000)
        let cold = w.launch()
        cold.prices.activate()
        let box = ScriptedBox()
        cold.site.connect(box)
        box.open(w.scheduler.nowMs)
        box.helloOk(uptimeMs: 60_000, cloud: nil, caps: [Contract.capPriceSpot, Contract.capAPIPassthrough])
        box.snap(uptimeMs: 60_000, gridW: 500)
        await w.run(1_000)
        #expect(cold.site.session.phase == .streaming)
        #expect(box.sent.contains("price.get"))
        // Yesterday's tomorrow is today: the window stays until a new one
        // lands.
        #expect(cold.prices.prices == prices)
        #expect(cold.prices.window?.origin == .cache)
    }

    @Test func theWidgetsRecordsAreReadBackWhenNothingIsSealed() async throws {
        let w = KeptHome()
        _ = try await w.liveThenKilled()
        // A launch from before the home file: only the App Group records.
        w.files.remove("home-home")
        for _ in 0..<200 where w.shared.read(PlanEntry.self, siteId: "home") == nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let cold = w.launch()
        #expect(cold.site.kept == nil)
        #expect(cold.prices.prices != nil)
        #expect(!cold.loadpoints.points.isEmpty)
        let moment = cold.nodes.planShare.moment(nowMs: w.scheduler.nowMs)
        #expect(moment.ageText != nil)
        #expect(moment.summary != PlanWord.noPlanYet.text)
    }

    @Test func withNothingKeptThePlanWaitsForAnAnswerBeforeSayingNone() async throws {
        let w = KeptHome()
        let home = w.launch()
        let waiting = home.nodes.planShare.moment(nowMs: w.scheduler.nowMs)
        #expect(waiting.state == .waiting)
        #expect(waiting.placeholder)
        #expect(waiting.summary != PlanWord.noPlanYet.text)
        home.site.connect(SimulatedBox.loopback(w.scheduler))
        w.look(home)
        await w.run(3_000)
        let answered = home.nodes.planShare.moment(nowMs: w.scheduler.nowMs)
        #expect(answered.state == .plan)
        #expect(answered.ageText == nil)
    }

    @Test func theHomeFileIsWrittenOnlyWhenItSaysSomethingNew() async throws {
        let w = KeptHome()
        let home = w.launch()
        home.site.connect(SimulatedBox.loopback(w.scheduler))
        w.look(home)
        await w.run(3_000)
        home.site.persistNow(wait: true)
        let first = try #require(w.files.read("home-home"))
        home.site.persistNow(wait: true)
        // Sealed with a fresh nonce each time: the same bytes mean no write.
        #expect(w.files.read("home-home") == first)
        let kept = try #require(w.files.readJSON(HomeCache.self, "home-home"))
        #expect(kept.hello?.caps.contains(Contract.capPlanDispatch) == true)
        #expect(kept.nodes?.contains(.grid) == true)
        #expect(kept.chargers?.value.points.isEmpty == false)
    }
}

@MainActor
@Suite struct CloudStampTests {
    /// FTW Cloud's prices and chargers reach the models as the cloud's,
    /// before the box session has said anything.
    @Test func theCloudsPricesAndCarsAreStampedAsTheClouds() async throws {
        let w = try CloudSite()
        w.keepFromEarlierLaunch(gridW: nil)
        let t0 = w.at - w.at % 86_400_000
        let prices = try w.box.seal(CloudWire.msgPrices, w.box.header(w.at) + [
            ("zone", .text("SE3")), ("currency", .text("SEK")), ("t0Ms", .int(t0)), ("slotMs", .int(900_000)),
            ("spotMinor", .array([.int(42), .int(40)])), ("totalMinor", .array([.int(118), .int(115)])),
        ])
        let lp = try w.box.seal(CloudWire.msgLP, w.box.header(w.at) + [
            ("controlRev", .int(3)),
            ("loadpoints", .array([.map([("id", .text("j3HZ")), ("src", .text("m")), ("plugged", .bool(true)),
                                        ("socPermille", .int(430)), ("socSource", .text("vehicle")), ("socAgeS", .int(60)),
                                        ("targetPermille", .int(800)), ("powerW", .int(2100))])])),
            ("feedback", .array([])),
        ])
        w.service.held = [try w.live(gridW: 1000), prices, lp]
        w.open()
        let priceModel = PriceModel(site: w.site)
        let loadpoints = LoadpointsModel(site: w.site, charging: nil, cache: nil)
        w.connectCloud()
        await w.run(60)
        #expect(priceModel.window?.origin == .cloud)
        #expect(priceModel.prices?.slots.first?.totalMinor == 118)
        #expect(loadpoints.stamp?.origin == .cloud)
        #expect(loadpoints.points.first?.socPct == 43)
        #expect(loadpoints.points.first?.powerW == 2100)
        #expect(!w.site.heardFromBox)
    }
}
