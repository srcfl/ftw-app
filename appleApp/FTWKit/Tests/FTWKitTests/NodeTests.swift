import Foundation
import Testing
@testable import FTWKit
import FTWDemo
import FTWShared

/// Now's nodes and the views they open: the live ring buffer, freshness per
/// source, history from the box's tiles, the plan, and changing the mode.
/// In English unless a test says otherwise.

// MARK: The ring buffer

@Suite struct RingBufferTests {
    @Test func keepsTheLatestInOrder() {
        var ring = RingBuffer<Int>(capacity: 3)
        #expect(ring.isEmpty)
        #expect(ring.last == nil)
        for i in 1...2 { ring.append(i) }
        #expect(ring.elements == [1, 2])
        #expect(ring.last == 2)
        for i in 3...5 { ring.append(i) }
        // Full: the oldest go first, and the order is still oldest first.
        #expect(ring.count == 3)
        #expect(ring.elements == [3, 4, 5])
        #expect(ring.last == 5)
        ring.append(6)
        #expect(ring.elements == [4, 5, 6])
        ring.removeAll()
        #expect(ring.isEmpty)
        ring.append(7)
        #expect(ring.elements == [7])
    }

    @MainActor
    @Test func aStreamThatStopsBreaksTheCurve() {
        let trace = LiveTrace()
        let t0 = 1_000_000.0
        for i in 0..<5 { trace.record([Contract.FID.pvW: -1000 - Double(i)], atMs: t0 + Double(i) * 1000) }
        // Ten seconds of silence, then the stream again.
        for i in 0..<3 { trace.record([Contract.FID.pvW: -900], atMs: t0 + 15_000 + Double(i) * 1000) }
        let points = trace.points(Contract.FID.pvW, sinceMs: 0)
        #expect(points.count == 8)
        #expect(points.map(\.t) == points.map(\.t).sorted())
        let runs = LiveTrace.runs(points)
        #expect(Set(runs.map(\.run)) == [0, 1])
        #expect(runs.filter { $0.run == 0 }.count == 5)
        // The window is a window: older points are not drawn.
        #expect(trace.points(Contract.FID.pvW, sinceMs: t0 + 15_000).count == 3)
        // The mode is not a reading.
        trace.record([Contract.FID.mode: 1], atMs: t0 + 20_000)
        #expect(trace.points(Contract.FID.mode, sinceMs: 0).isEmpty)
    }

    @MainActor
    @Test func theRingHoldsTenMinutesAndNoMore() {
        let trace = LiveTrace()
        for i in 0..<(LiveTrace.capacity + 50) { trace.record([Contract.FID.gridW: Double(i)], atMs: Double(i) * 1000) }
        let points = trace.points(Contract.FID.gridW, sinceMs: 0)
        #expect(points.count == LiveTrace.capacity)
        #expect(points.first?.v == 50)
        #expect(points.last?.v == Double(LiveTrace.capacity + 49))
    }

    @MainActor
    @Test func recordsWhatArrivesAndNothingWhileTheStreamIsQuiet() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        await rig.run(5_000)
        let before = home.nodes.live.points(Contract.FID.batteryW, sinceMs: 0)
        #expect(before.count >= 3)
        // Silence: no frames, so no points, however long the clock runs.
        box.mute = true
        await rig.run(10_000)
        #expect(home.nodes.live.points(Contract.FID.batteryW, sinceMs: 0).count == before.count)
        box.mute = false
        await rig.run(3_000)
        let after = home.nodes.live.points(Contract.FID.batteryW, sinceMs: 0)
        #expect(after.count > before.count)
        #expect(Set(LiveTrace.runs(after).map(\.run)).count == 2)
    }
}

// MARK: Freshness, per source

@Suite struct NodeFreshnessTests {
    static func session(state: SourceState = .live, srcId: String? = "inv", lastOkAgo: Double = 400) -> SessionState {
        var s = SessionState()
        s.uptimeMs = 3_600_000
        s.fields = [Contract.FID.pvW: -2_000, Contract.FID.gridW: 300]
        s.dict = [
            Contract.FID.pvW: FieldDef(name: "pv_w", unit: "W", srcId: srcId),
            Contract.FID.gridW: FieldDef(name: "grid_w", unit: "W", srcId: "meter"),
        ]
        s.sources = [
            "inv": Source(kind: "inverter", name: "sungrow", lastOkMs: 3_600_000 - lastOkAgo, staleAfterMs: 10_000, state: state),
            "meter": Source(kind: "meter", name: "sdm630", lastOkMs: 3_600_000 - 200, staleAfterMs: 10_000, state: .live),
        ]
        return s
    }

    @Test func liveIsTheCarrierAndTheSourceAtOnce() {
        let f = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(), carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        #expect(f.live)
        #expect(f.srcState == .live)
        #expect(f.ageMs == 400)
        #expect(f.sourceName == "sungrow")
        // The same reading over no carrier is not live, however healthy.
        let none = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(), carrier: .none, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        #expect(!none.live)
        #expect(none.srcState == .live)
    }

    @Test func aQuietDeviceIsNotLiveWhileItsNeighbourIs() {
        let s = Self.session(state: .stale, lastOkAgo: 40_000)
        let pv = NodeFreshness.of(fid: Contract.FID.pvW, session: s, carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        let grid = NodeFreshness.of(fid: Contract.FID.gridW, session: s, carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        #expect(!pv.live)
        #expect(pv.srcState == .stale)
        #expect(pv.ageMs == 40_000)
        #expect(grid.live)
        let down = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(state: .down), carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        #expect(down.srcState == .down)
    }

    @Test func aQuietStreamLagsAndACacheIsStale() {
        let lagging = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(), carrier: .relay, streamQuietMs: 5_000, shelfMs: nil, fallback: .live)
        #expect(lagging.srcState == .lagging)
        #expect(!lagging.live)
        #expect(lagging.ageMs == 5_400)
        let cached = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(), carrier: .cache, streamQuietMs: 0, shelfMs: 60_000, fallback: .stale)
        #expect(cached.srcState == .stale)
        #expect(cached.carrier == .cache)
        #expect(cached.ageMs == 60_400)
        #expect(!cached.live)
    }

    @Test func noFieldIsNeverAndNoSourceTakesTheHomes() {
        let never = NodeFreshness.of(fid: Contract.FID.batteryW, session: Self.session(), carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live)
        #expect(never.srcState == .never)
        #expect(!never.live)
        // A field the box computes itself names no source.
        let computed = NodeFreshness.of(fid: Contract.FID.pvW, session: Self.session(srcId: nil), carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .lagging)
        #expect(computed.srcState == .lagging)
    }

    @Test func nowDrawsEachNodeWithItsOwnFreshness() {
        let s = Self.session(state: .stale, lastOkAgo: 40_000)
        let readings = AppWords.$language.withValue(.en) {
            NowFlow.readings(
                fields: s.fields,
                freshness: { NodeFreshness.of(fid: $0, session: s, carrier: .relay, streamQuietMs: 0, shelfMs: nil, fallback: .live) }
            )
        }
        let solar = try? #require(readings.first { $0.node == .solar })
        let grid = try? #require(readings.first { $0.node == .grid })
        #expect(solar?.freshness.live == false)
        #expect(grid?.freshness.live == true)
        // Solar shows what it makes, the grid what it buys; no minus sign.
        #expect(solar?.watts == 2_000)
        #expect(solar?.word == "making")
        #expect(grid?.word == "buying")
        // No battery and no car field: no node rather than a dead one.
        #expect(!readings.contains { $0.node == .battery || $0.node == .car })
    }
}

// MARK: Several devices behind one node

@Suite struct SourcesTests {
    @Test func twoInvertersAreTwoDevices() throws {
        let status = try JSON(parsing: Bytes(#"""
        {"drivers": {
          "sungrow": {"status": "ok", "pv_w": -2400, "bat_w": -900, "bat_soc": 0.62},
          "fronius": {"status": "ok", "pv_w": -1500},
          "old": {"status": "offline", "pv_w": -10},
          "easee": {"status": "ok", "ev_w": 0}
        }}
        """#.utf8))
        let devices = SourcesModel.devices(status)
        let solar = try #require(devices[.solar])
        #expect(solar.map(\.name) == ["fronius", "sungrow"])
        #expect(solar.map(\.watts) == [1_500, 2_400])
        #expect(devices[.battery]?.first?.levelPct == 62)
        #expect(devices[.battery]?.first?.shownW == -900)
        #expect(devices[.car]?.count == 1)
    }

    @MainActor
    @Test func theSplitIsReadWhenAViewOpensAndNotOnATimer() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        await rig.run(1_500)
        home.nodes.sources.activate(.solar)
        await rig.run(1_000)
        let split = try #require(home.nodes.sources.split(.solar))
        #expect(split.map(\.name) == ["fronius", "sungrow"])
        // One battery is no split worth showing.
        #expect(home.nodes.sources.split(.battery) == nil)
        // A steady total asks nothing more, however long the view is open.
        let reads = box.receivedRequests.filter { $0 == "GET /api/status" }.count
        #expect(reads == 1)
        await rig.run(30_000, step: 250)
        let later = box.receivedRequests.filter { $0 == "GET /api/status" }.count
        #expect(later - reads <= 3, "the split was read \(later - reads) times in 30 s")
        home.nodes.sources.deactivate(.solar)
    }
}

// MARK: History

@Suite struct HistoryGeometryTests {
    /// Values the box's go/protocol/tiles_test.go checks against the web
    /// app's own functions: the same tile on all three.
    @Test func tilesAreTheBoxesTiles() {
        #expect(HistoryGeometry.pointsPerTile(.fiveMinutes) == 144)
        #expect(HistoryGeometry.pointsPerTile(.hour) == 168)
        let start = HistoryGeometry.tileStart(.fiveMinutes, 1_760_000_000_000)
        #expect(start.truncatingRemainder(dividingBy: 43_200_000) == 0)
        #expect(HistoryGeometry.tileID(.fiveMinutes, stride: 3, startMs: start) == "5m/3/40740")
        #expect(HistoryGeometry.etag(Bytes(0..<16)) == "c8fff215")
        #expect(HistoryGeometry.etag([]) == "811c9dc5")
    }

    @Test func twoDaysAtFiveMinutesIsOneQuery() {
        let now = 1_791_799_200_000.0
        let plan = HistoryGeometry.plan(.fiveMinutes, fromMs: now - HistoryModel.spanMs, toMs: now, maxPoints: HistoryModel.maxPoints)
        #expect(plan.res == .fiveMinutes)
        #expect(plan.stride == 1)
        #expect(plan.tiles.first!.startMs <= now - HistoryModel.spanMs)
        #expect(plan.tiles.last!.startMs + 43_200_000 >= now)
        #expect(plan.tiles.reduce(0) { $0 + $1.points } <= HistoryModel.maxPoints)
    }

    @Test func aMissingTileStaysMissingAndAHoleIsNotZero() {
        let plan = HistoryGeometry.TilePlan(res: .fiveMinutes, stride: 72, stepMs: 21_600_000, tiles: [
            .init(tileId: "a", startMs: 0, points: 2),
            .init(tileId: "b", startMs: 43_200_000, points: 2),
            .init(tileId: "c", startMs: 86_400_000, points: 2),
        ])
        let a = HistChunk(tileId: "a", etag: "", res: .fiveMinutes, startMs: 0, stepMs: 21_600_000, series: ["pv_w", "grid_w"], data: HistoryGeometry.pack([[-100, -200], [5, missingSample]]), partial: false)
        let c = HistChunk(tileId: "c", etag: "", res: .fiveMinutes, startMs: 86_400_000, stepMs: 21_600_000, series: ["grid_w"], data: HistoryGeometry.pack([[0, 7]]), partial: true)
        let frame = HistoryGeometry.assemble(plan, names: ["grid_w", "pv_w"], tiles: ["a": a, "c": c])
        #expect(frame.points == 6)
        #expect(frame.columns[0] == [5, missingSample, missingSample, missingSample, 0, 7])
        #expect(frame.columns[1] == [-100, -200, missingSample, missingSample, missingSample, missingSample])
        #expect(frame.value("grid_w", at: 4) == 0)
        #expect(frame.value("grid_w", at: 1) == nil)
        let clipped = HistoryGeometry.clip(frame, fromMs: 21_600_000, toMs: 108_000_000)
        #expect(clipped.startMs == 21_600_000)
        #expect(clipped.points == 4)
    }

    @Test func energyIsTheMeanPowerTimesTheStep() {
        let step = 300_000.0
        let samples = [
            HistorySample(startMs: 0, stepMs: step, watts: 1_200),
            HistorySample(startMs: step, stepMs: step, watts: -600),
            HistorySample(startMs: 2 * step, stepMs: step, watts: nil),
            HistorySample(startMs: 3 * step, stepMs: step, watts: 2_400),
        ]
        let all = EnergyToday.sum(samples, fromMs: 0)
        #expect(all.inWh == 100 + 200)
        #expect(all.outWh == 50)
        #expect(all.missingMs == step)
        // From the middle of the first step: only its second half counts.
        let half = EnergyToday.sum(samples, fromMs: step / 2)
        #expect(half.inWh == 50 + 200)
    }
}

@Suite struct HistoryWireTests {
    /// Over the whole stack (relay, Noise, frames, session) to the simulated
    /// box: tiles arrive, and a second ask with the closed tiles in `have`
    /// gets only the one still filling.
    @MainActor
    @Test func closedTilesCrossTheWireOnce() async throws {
        let rig = Rig()
        await rig.run(500)
        #expect(rig.session.state.phase == .streaming)
        let now = rig.scheduler.nowMs
        let bin = Bin()
        let ask = HistQuery(series: HistoryModel.series, res: .fiveMinutes, fromMs: now - HistoryModel.spanMs, toMs: now, maxPoints: HistoryModel.maxPoints)
        let task = Task { try await rig.session.history(ask) { bin.chunks.append($0) } }
        await rig.run(500)
        let end = try await task.value
        let first = bin.chunks
        #expect(end.resActual == .fiveMinutes)
        #expect(first.count == HistoryGeometry.plan(.fiveMinutes, fromMs: ask.fromMs, toMs: now, maxPoints: HistoryModel.maxPoints).tiles.count)
        #expect(first.filter(\.partial).count == 1)
        for chunk in first {
            #expect(chunk.etag == HistoryGeometry.etag(chunk.data))
            #expect(chunk.series == HistoryModel.series)
            #expect(chunk.data.count == HistoryModel.series.count * 144 * 4)
        }

        let bin2 = Bin()
        let again = HistQuery(series: ask.series, res: .fiveMinutes, fromMs: ask.fromMs, toMs: now, have: first.filter { !$0.partial }.map { ($0.tileId, $0.etag) }, maxPoints: ask.maxPoints)
        let task2 = Task { try await rig.session.history(again) { bin2.chunks.append($0) } }
        await rig.run(500)
        _ = try await task2.value
        #expect(bin2.chunks.map(\.tileId) == first.filter(\.partial).map(\.tileId))
    }

    @MainActor
    final class Bin {
        var chunks = [HistChunk]()
    }

    @MainActor
    @Test func aModelAssemblesTwoDaysAndToday() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = CarTextTests.stockholm
        let history = HistoryModel(site: home.site, calendar: cal)
        history.activate()
        await rig.run(3_000)
        #expect(history.loaded)
        let frame = try #require(history.frame)
        // Two days at five minutes, ending now.
        #expect(abs(Double(frame.points) * frame.stepMs - HistoryModel.spanMs) <= frame.stepMs * 2)
        #expect(frame.startMs + Double(frame.points) * frame.stepMs >= rig.scheduler.nowMs - frame.stepMs)
        // Noon in October: the sun has been up for five hours.
        let solar = try #require(history.today(.solar))
        #expect(solar.inWh > 500)
        #expect(solar.outWh == 0)
        let home48 = history.samples(.home, fromMs: rig.scheduler.nowMs - HistoryModel.spanMs)
        #expect(home48.allSatisfy { ($0.watts ?? 0) >= 0 })
        #expect(home48.filter { $0.watts != nil }.count > 500)
        // The midnight is the household's.
        #expect(cal.component(.hour, from: Date(timeIntervalSince1970: history.midnightMs / 1000)) == 0)
    }
}

// MARK: The plan

@Suite struct PlanTests {
    @MainActor
    @Test func thePlanArrivesAndLandsOnTheSession() async throws {
        let rig = Rig()
        await rig.run(500)
        let task = Task { try await rig.session.plan() }
        await rig.run(500)
        let plan = try await task.value
        #expect(!plan.stale)
        #expect(plan.slots.count > 40)
        #expect((plan.slots.first?.startMs ?? .infinity) <= rig.scheduler.nowMs)
        #expect(plan.slots.allSatisfy { $0.priceMinor != nil && PlanText.reasons[$0.reason] != nil })
        #expect(rig.session.state.plan == plan)
    }

    @Test func theBatteryInOneSentence() {
        let h = 3_600_000.0
        let t = 1_791_799_200_000.0
        let slots = [
            PlanSlot(startMs: t, durationMs: h, batteryW: 2_500, gridW: 3_000, priceMinor: 30, reason: "cheap_import"),
            PlanSlot(startMs: t + h, durationMs: h, batteryW: 2_000, gridW: 2_400, priceMinor: 32, reason: "cheap_import"),
            PlanSlot(startMs: t + 2 * h, durationMs: h, batteryW: -1_800, gridW: 0, priceMinor: 160, reason: "expensive_import"),
        ]
        AppWords.$language.withValue(.en) {
            #expect(PlanText.battery(slots, stale: false, nowMs: t, zone: CarTextTests.utc) == "Charges at up to 2.5\u{00A0}kW until 12:00, power is cheap. Then gives power, power is dear.")
            #expect(PlanText.battery(slots, stale: true, nowMs: t, zone: CarTextTests.utc).hasPrefix("Your box couldn't plan ahead"))
            #expect(PlanText.grid(slots, stale: false) == "Expects to buy 5.4\u{00A0}kWh over the next 12 hours.")
        }
        AppWords.$language.withValue(.sv) {
            #expect(PlanText.battery(slots, stale: false, nowMs: t, zone: CarTextTests.utc) == "Laddar med upp till 2,5\u{00A0}kW till 12:00, elen är billig. Sedan ger batteriet ström, elen är dyr.")
        }
    }
}

// MARK: Changing the mode

@Suite struct ModeTests {
    @MainActor
    @Test func sentReceivedThenWhatTheBoxDid() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let box = try #require(rig.box)
            let mode = home.nodes.mode
            mode.activate()
            await rig.run(1_500)
            #expect(mode.actual == "planner_passive_arbitrage")
            #expect(mode.canControl)
            #expect(mode.label == "Plan · Balanced")
            let rev = box.house.planRev

            let change = Task { await mode.set("self_consumption") }
            await rig.run(50)
            // At once: the choice, and "Sent". Nothing the box has not said.
            #expect(mode.shown == "self_consumption")
            #expect(mode.actual == "planner_passive_arbitrage")
            #expect(mode.outcome?.sent == .done)
            #expect(mode.outcome?.received == .active)
            #expect(mode.outcome?.text == "Sending Own use to your box…")
            await rig.run(300)
            // The box's receipt, then its result.
            #expect(mode.change?.acked == true)
            #expect(mode.outcome?.received == .done)
            #expect(mode.outcome?.done == .active)
            await rig.run(1_000)
            await change.value
            #expect(mode.change?.result == .applied)
            #expect(mode.outcome?.done == .done)
            #expect(mode.outcome?.tone == .done)
            #expect(mode.outcome?.text == "Your box now runs Own use.")
            await rig.run(1_500)
            #expect(mode.actual == "self_consumption")
            #expect(box.house.planRev > rev)
            #expect(box.receivedCommands.last == Contract.opSetMode)
            // The receipt goes once the screen shows the effect.
            await rig.run(ModeModel.doneShownMs)
            #expect(mode.change == nil)
            #expect(mode.shown == "self_consumption")
        }
    }

    @MainActor
    @Test func aRefusalSnapsBack() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            await rig.run(1_500)
            let change = Task { await mode.set("no_such_mode") }
            await rig.run(2_000)
            await change.value
            #expect(mode.change?.result == .refused("Something changed at home while this was sending. Try again."))
            #expect(mode.outcome?.tone == .failed)
            #expect(mode.outcome?.done == .failed)
            #expect(mode.shown == "planner_passive_arbitrage")
        }
    }

    @MainActor
    @Test func takenButNeverConfirmedIsItsOwnAnswer() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            let box = try #require(rig.box)
            await rig.run(1_500)
            box.neverConfirm = true
            let change = Task { await mode.set("idle") }
            await rig.run(Session.cmdConfirmTimeoutMs + 1_000, step: 250)
            await change.value
            #expect(mode.change?.result == .unconfirmed)
            #expect(mode.outcome?.done == .waiting)
            #expect(mode.outcome?.tone == .warning)
            // Shown as asked, never as done.
            #expect(mode.shown == "idle")
        }
    }

    @MainActor
    @Test func neverReachingTheBoxSaysSo() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            let box = try #require(rig.box)
            await rig.run(1_500)
            box.mute = true
            let change = Task { await mode.set("charge") }
            await rig.run(Session.cmdAckTimeoutMs + 500, step: 250)
            await change.value
            #expect(mode.change?.result == .refused("That did not reach your box. Try again."))
            #expect(mode.outcome?.received == .failed)
            #expect(mode.shown == "planner_passive_arbitrage")
        }
    }

    @MainActor
    @Test func aPlanningStyleIsAPreference() async throws {
        try await AppWords.$language.withValue(.sv) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            let box = try #require(rig.box)
            mode.activate()
            await rig.run(1_500)
            #expect(mode.prefs?.safetyK == 0.3)
            #expect(mode.label == "Plan · Balanserad")
            let careful = try #require(ModeModel.styles.first { $0.key == "careful" })
            let change = Task { await mode.setStyle(careful) }
            await rig.run(50)
            #expect(mode.shownStyle == careful)
            await rig.run(2_500)
            await change.value
            #expect(box.house.safetyK == 0.6)
            #expect(box.receivedCommands.last == Contract.opPlannerPrefsSet)
            #expect(mode.outcome?.text == "Planeringsstilen är nu Försiktig.")
            #expect(mode.prefs?.safetyK == 0.6)
            #expect(mode.label == "Plan · Försiktig")

            let sell = Task { await mode.setExport(true) }
            await rig.run(2_500)
            await sell.value
            #expect(box.house.batteryExport == "allowed")
            #expect(mode.actual == "planner_arbitrage")
        }
    }
}

// MARK: Words

@Suite struct NodeWordsTests {
    /// Every sentence Now and the nodes' views hand to `L`, `NodeWords` or
    /// `AppWords` has a Swedish entry. Read from the source, so a new
    /// sentence cannot slip through.
    @Test func everySentenceHasSwedish() throws {
        let files = [
            "appleApp/FTW/UI/NowView.swift", "appleApp/FTW/UI/FlowDiagram.swift", "appleApp/FTW/UI/NodeView.swift",
            "appleApp/FTW/UI/NodeCharts.swift", "appleApp/FTW/UI/ModeSheet.swift", "appleApp/FTW/UI/PriceChart.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/EnergyNode.swift", "appleApp/FTWKit/Sources/FTWKit/State/NowFlow.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/ModeModel.swift", "appleApp/FTWKit/Sources/FTWKit/State/PlanModel.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/HistoryModel.swift",
        ]
        let pattern = #/(?:\bL|NodeWords\.(?:text|format)|AppWords\.(?:text|format))\("((?:[^"\\]|\\.)*)"/#
        var english = Set<String>()
        for file in files {
            for match in try RepoFiles.read(file).matches(of: pattern) {
                english.insert(String(match.1).replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        #expect(english.count > 100)
        // Words handed over as values rather than written at the call.
        english.formUnion(ModeWords.names.values)
        english.formUnion(ModeWords.helps.values)
        english.formUnion(ModeModel.styles.flatMap { [$0.name, $0.help] })
        english.formUnion(PlanText.reasons.values)
        for word in english.sorted() {
            #expect(NodeWords.sv[word] != nil || AppWords.sv[word] != nil, "no Swedish for \"\(word)\"")
        }
        for (en, sv) in NodeWords.sv {
            #expect(!sv.isEmpty)
            #expect(en.components(separatedBy: "%@").count == sv.components(separatedBy: "%@").count, "\(en)")
        }
    }

    @Test func aModeTheAppHasNotHeardOfKeepsTheBoxsLabel() {
        let unknown = ModeInfo(key: "planner_future", label: "Future plan", tooltip: "Something new.", tier: "primary")
        AppWords.$language.withValue(.sv) {
            #expect(ModeWords.name(unknown) == "Future plan")
            #expect(ModeWords.help(unknown) == "Something new.")
            #expect(ModeWords.name(SimulatedBox.modes[0]) == "Plan")
            #expect(ModeWords.name(SimulatedBox.modes[2]) == "Stoppa batterierna")
        }
    }
}

/// The demo home in an `AppModel`, on a clock the test moves: noon on a
/// Monday in October, in Stockholm.
@MainActor
final class DemoRig {
    let scheduler: ManualScheduler
    var box: SimulatedBox?
    var app: AppModel!

    init(nowMs: Double = CarTextTests.t) {
        scheduler = ManualScheduler(nowMs: nowMs)
        app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { [unowned self] s in
            let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
            box.resultDelayMs = 900
            self.box = box
            return LoopbackCarrier(box: box, scheduler: s)
        })
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
}
