import Foundation
import Testing
@testable import FTWKit
@testable import FTWWire
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
    @Test func theRingHoldsFiveMinutesAtTheFastestAndNoMore() {
        let trace = LiveTrace()
        // Five frames a second, the most the box sends through FTW Cloud.
        for i in 0..<(LiveTrace.capacity + 50) { trace.record([Contract.FID.gridW: Double(i)], atMs: Double(i) * 200) }
        let points = trace.points(Contract.FID.gridW, sinceMs: 0)
        #expect(points.count == LiveTrace.capacity)
        #expect(points.first?.v == 50)
        #expect(points.last?.v == Double(LiveTrace.capacity + 49))
        #expect(points.last!.t - points.first!.t >= LiveTrace.windowMs - 200)
    }

    /// Frames come as readings land, so most carry another device's news.
    /// A device whose value did not move repeats once a second, as it did
    /// at 1 Hz, and its curve keeps one run.
    @MainActor
    @Test func aFrameThatCarriesAnotherDevicesReadingAddsNoPoint() {
        let trace = LiveTrace()
        let t0 = 1_000_000.0
        for i in 0..<50 {
            trace.record([Contract.FID.gridW: Double(1000 + i), Contract.FID.pvW: -2000], atMs: t0 + Double(i) * 200)
        }
        #expect(trace.points(Contract.FID.gridW, sinceMs: 0).count == 50)
        let pv = trace.points(Contract.FID.pvW, sinceMs: 0)
        #expect(pv.count == 10)
        #expect(Set(LiveTrace.runs(pv).map(\.run)).count == 1)
        // A move goes in at once, whatever the last point's age.
        trace.record([Contract.FID.pvW: -2100], atMs: t0 + 50 * 200)
        #expect(trace.points(Contract.FID.pvW, sinceMs: 0).last?.v == -2100)
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

    @Test func aLiveReadingThroughFTWCloudIsLive() {
        // 0.3.0 said "Not live, just now" on every node read through FTW
        // Cloud, and Now's flow stood still: the rule knew only the relay.
        for carrier: CarrierKind in [.relay, .webrtc, .cloud] {
            #expect(NodeFreshness(carrier: carrier, srcState: .live, ageMs: 0, sourceName: nil).live, "\(carrier)")
            #expect(!NodeFreshness(carrier: carrier, srcState: .stale, ageMs: 0, sourceName: nil).live, "\(carrier)")
        }
        for carrier: CarrierKind in [.cache, .none] {
            #expect(!NodeFreshness(carrier: carrier, srcState: .live, ageMs: 0, sourceName: nil).live, "\(carrier)")
        }
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

    @MainActor
    @Test func aViewOpenedBeforeTheStreamReadsOnceItFlows() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        // Opened at launch, as `-FTWNode solar` does: nothing streams yet.
        home.nodes.sources.activate(.solar)
        #expect(home.nodes.sources.readAtMs == nil)
        await rig.run(2_000)
        #expect(home.nodes.sources.split(.solar)?.count == 2)
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

/// A node's history on a fixed grid: points keep their identity as data
/// arrives, a stretch still being fetched is bridged by an estimate, and a
/// hole the box confirms is a break.
@Suite struct HistoryPlotTests {
    static let step = 300_000.0

    func sample(_ i: Int, _ w: Double?, fetching: Bool = false) -> HistorySample {
        HistorySample(startMs: Double(i) * Self.step, stepMs: Self.step, watts: w, fetching: fetching)
    }

    @Test func everyPointSitsOnTheGrid() {
        let points = HistoryPlot.points([sample(0, 100), sample(1, 200), sample(2, 300)], fromMs: 0)
        #expect(points.map(\.id) == [0, Self.step, 2 * Self.step])
        #expect(points.map(\.t) == [Self.step / 2, Self.step * 1.5, Self.step * 2.5])
        #expect(Set(points.map(\.run)).count == 1)
        #expect(points.allSatisfy { $0.kind == .measured })
    }

    @Test func aStretchBeingFetchedIsAStraightEstimate() {
        let points = HistoryPlot.points([sample(0, 100), sample(1, nil, fetching: true), sample(2, nil, fetching: true), sample(3, 400)], fromMs: 0)
        let estimates = points.filter { $0.kind == .estimate }
        #expect(estimates.map(\.id) == [Self.step, 2 * Self.step])
        #expect(estimates.map(\.v) == [200, 300])
        // The measured line breaks under the bridge: it never claims a value
        // there.
        let measured = points.filter { $0.kind == .measured }
        #expect(measured.count == 2)
        #expect(measured[0].run != measured[1].run)
        // Once the data arrives, the same points are measured: an estimate
        // grows into its value.
        let arrived = HistoryPlot.points([sample(0, 100), sample(1, 150), sample(2, 380), sample(3, 400)], fromMs: 0)
        #expect(arrived.map(\.id) == points.map(\.id))
        #expect(arrived.allSatisfy { $0.kind == .measured })
        #expect(Set(arrived.map(\.run)).count == 1)
    }

    @Test func aHoleTheBoxConfirmsIsABreak() {
        let points = HistoryPlot.points([sample(0, 100), sample(1, nil), sample(2, nil), sample(3, 400)], fromMs: 0)
        #expect(points.map(\.id) == [0, 3 * Self.step])
        #expect(points.allSatisfy { $0.kind == .measured })
        #expect(points[0].run != points[1].run)
    }

    @Test func noBridgeWithoutAMeasuredPointOnEachSide() {
        let tail = HistoryPlot.points([sample(0, 100), sample(1, nil, fetching: true)], fromMs: 0)
        #expect(tail.map(\.kind) == [.measured])
        let head = HistoryPlot.points([sample(0, nil, fetching: true), sample(1, 100)], fromMs: 0)
        #expect(head.map(\.kind) == [.measured])
        let afterHole = HistoryPlot.points([sample(0, 100), sample(1, nil), sample(2, nil, fetching: true), sample(3, 300)], fromMs: 0)
        #expect(afterHole.filter { $0.kind == .estimate }.isEmpty)
    }

    /// A tile that has not arrived is on its way while the model loads; a
    /// hole in a tile that arrived is the box saying it has nothing.
    @Test func onlyATileNotYetHereIsFetching() {
        let frame = HistoryGeometry.Frame(
            startMs: 0, stepMs: Self.step, points: 4, names: ["pv_w"],
            columns: [[100, missingSample, missingSample, 400]],
            arrived: [true, true, false, true]
        )
        let loading = HistoryModel.samples(frame, node: .solar, fromMs: 0, fetching: true)
        #expect(loading.map(\.fetching) == [false, false, true, false])
        let settled = HistoryModel.samples(frame, node: .solar, fromMs: 0, fetching: false)
        #expect(settled.allSatisfy { !$0.fetching })
    }
}

/// The demo's slow tile, end to end: while it is on its way the chart has
/// an estimate there; once it lands the same points are measured.
@Suite struct HistoryGapTests {
    @MainActor
    @Test func aTileHeldBackIsBridgedThenFilled() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let box = try #require(rig.box)
        box.holdTileMs = 2_000
        let history = try #require(rig.app.home).nodes.history
        history.activate()
        await rig.run(1_000)
        let from = rig.scheduler.nowMs - HistoryModel.spanMs
        let waiting = history.samples(.home, fromMs: from)
        #expect(history.loading)
        #expect(waiting.contains { $0.fetching })
        let bridged = HistoryPlot.points(waiting, fromMs: from)
        let estimates = bridged.filter { $0.kind == .estimate }
        #expect(!estimates.isEmpty)
        await rig.run(2_500)
        #expect(!history.loading)
        let filled = HistoryPlot.points(history.samples(.home, fromMs: from), fromMs: from)
        #expect(filled.allSatisfy { $0.kind == .measured })
        // The points that were estimates are now measured, with the same
        // identity.
        let ids = Set(filled.map(\.id))
        #expect(estimates.allSatisfy { ids.contains($0.id) })
    }
}

/// What a chart says under the finger.
@Suite struct ReadoutTests {
    static let step = 300_000.0

    func sample(_ i: Int, _ w: Double?, fetching: Bool = false) -> HistorySample {
        HistorySample(startMs: Double(i) * Self.step, stepMs: Self.step, watts: w, fetching: fetching)
    }

    @Test func aSlotAheadSaysWhatThePlanDoesWhyAndThePrice() {
        AppWords.$language.withValue(.en) {
            let hour = 3_600_000.0
            let bars = [ChartSlot(startMs: 0, endMs: hour, watts: 2_500, reason: "cheap_import"), ChartSlot(startMs: hour, endMs: 2 * hour, watts: 40, reason: "idle")]
            let prices = [ChartPrice(startMs: 0, endMs: hour, minor: 65.5), ChartPrice(startMs: hour, endMs: 2 * hour, minor: 120)]
            let first = Readouts.ahead(.battery, bars, prices, currency: "SEK", forecast: false, at: 10)
            #expect(first?.what == "charging 2.5\u{00A0}kW · \(PlanText.reason("cheap_import")) · 65.5 öre/kWh")
            // A resting slot gives no reason, only the price.
            let second = Readouts.ahead(.battery, bars, prices, currency: "SEK", forecast: false, at: hour + 10)
            #expect(second?.what == "resting 40\u{00A0}W · 120 öre/kWh")
            // Swedish writes the decimal comma.
            AppWords.$language.withValue(.sv) {
                #expect(Readouts.ahead(.battery, bars, prices, currency: "SEK", forecast: false, at: 10)?.what.hasSuffix("65,5 öre/kWh") == true)
            }
            let both = Readouts.ahead(.battery, bars, prices, currency: "SEK", forecast: false, range: 0...(2 * hour))
            #expect(both?.what.hasPrefix("↑ \(AppWords.energy(2_500)) ↓ \(AppWords.energy(0)) · average") == true)
        }
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
    /// What the plan saves comes from the planner's own document: its cost,
    /// the no-battery baseline, and the levels at either end.
    @Test func theSavingComesFromThePlannersDocument() {
        let plan: JSON = [
            "total_cost_ore": 4350, "initial_soc": 1,
            "baselines": ["no_battery_ore": 7168],
            "actions": .array([["slot_start_ms": 1_000, "slot_len_min": 15, "soc": .number(0.98)]]),
        ]
        #expect(PlanModel.saving(plan) == PlanSaving(costMinor: 4350, noBatteryMinor: 7168, startLevel: 1, endLevel: 0.98, endMs: 901_000))
        // A plan without a baseline says nothing.
        #expect(PlanModel.saving(["total_cost_ore": 4350, "initial_soc": 1]) == nil)
    }

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
        // The box says where each slot leaves the battery, in thousandths.
        #expect(plan.slots.allSatisfy { ($0.socPermille ?? -1) >= 0 && ($0.socPermille ?? 2_000) <= 1_000 })
        #expect(rig.session.state.plan == plan)
    }

    /// The level travels on the wire when the box sends it, and stays nil
    /// from a box that does not.
    @Test func theLevelRoundTripsOnTheWire() {
        let slot = PlanSlot(startMs: 1_000, durationMs: 900_000, batteryW: -1_200, gridW: 0, priceMinor: 160, reason: "expensive_import", socPermille: 624)
        let plan = Plan(rev: 3, uptimeMs: 0, slots: [slot, PlanSlot(startMs: 901_000, durationMs: 900_000, batteryW: 0, gridW: 300, priceMinor: 90, reason: "idle")], stale: false, ceilingW: nil)
        let back = Plan(plan.wire)
        #expect(back.slots[0].socPermille == 624)
        #expect(back.slots[1].socPermille == nil)
    }

    /// The plan's entry takes the level from the wire, and from the
    /// planner's own document for a box that sends none on its plan.
    @Test func theEntryTakesTheLevelFromTheWireOrThePlanner() {
        let a = PlanSlot(startMs: 0, durationMs: 900_000, batteryW: -1_200, gridW: 0, priceMinor: 160, reason: "expensive_import", socPermille: 624)
        let b = PlanSlot(startMs: 900_000, durationMs: 900_000, batteryW: -1_200, gridW: 0, priceMinor: 160, reason: "expensive_import")
        let plan = Plan(rev: 1, uptimeMs: 0, slots: [a, b], stale: false, ceilingW: nil)
        let entry = PlanEntry.live(plan: plan, points: [], windows: [:], prices: nil, levels: [(startMs: 900_000, endMs: 1_800_000, pct: 58)])
        #expect(entry.battery?.map(\.levelPct) == [62.4, 58])
        #expect(PlanEntry.live(plan: plan, points: [], windows: [:], prices: nil).battery?.map(\.levelPct) == [62.4, nil])
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

    /// A change of the person's own sets the new plan beside the one
    /// before it, until the next plan; the stops of the style's scale sit
    /// at even steps.
    @MainActor
    @Test func aChangeShowsWhatThePlanMoved() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let home = try #require(rig.app.home)
            let mode = home.nodes.mode, plan = home.nodes.plan
            mode.activate()
            plan.activate()
            await rig.run(1_500)
            let before = try #require(plan.plan)
            #expect(plan.move == nil)
            let change = Task { await mode.setStyle(ModeModel.styles[0]) }
            await rig.run(2_000)
            await change.value
            await rig.run(8_000)
            let move = try #require(plan.move)
            #expect(move.before == before)
            #expect(plan.plan?.rev != before.rev)
            // Asked again past the hold, the box's next plan is its own.
            await rig.run(PlanModel.moveHoldMs + 1_000)
            mode.deactivate()
            plan.follow()
            await rig.run(1_000)
            #expect(plan.move == nil || plan.move == move)
        }
        #expect(ModeModel.stop(at: 0) == 0 && ModeModel.stop(at: 1) == 4)
        #expect(ModeModel.stop(at: 0.6) == 2 && ModeModel.stop(at: 0.63) == 3)
        #expect(ModeModel.stop(at: -1) == 0 && ModeModel.stop(at: .nan) == 2)
        #expect(ModeModel.fraction(of: 2) == 0.5 && ModeModel.fraction(of: 9) == 1)
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
            mode.activate()
            await rig.run(1_500)
            box.neverConfirm = true
            let change = Task { await mode.set("idle") }
            await rig.run(Session.cmdConfirmTimeoutMs + 1_000, step: 250)
            await change.value
            #expect(mode.change?.result == .unconfirmed)
            #expect(mode.outcome?.done == .waiting)
            #expect(mode.outcome?.tone == .warning)
            // A frame with the box's own mode: that is what shows, with the
            // ask beside it, never the ask as the mode.
            await rig.run(1_500)
            #expect(mode.actual == "planner_passive_arbitrage")
            #expect(mode.shown == "planner_passive_arbitrage")
            #expect(mode.label == "Plan · Balanced")
            #expect(mode.doubt == "Asked for Stop batteries. Your box has not confirmed it.")
        }
    }

    /// Between the box's "applied" and its next frame the old mode is still
    /// on lane 0. The choice stands until that frame, so nothing flicks back.
    @MainActor
    @Test func anAppliedChoiceStandsUntilTheBoxReportsAgain() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            await rig.run(1_500)
            let change = Task { await mode.set("self_consumption") }
            var seen: Set<String> = []
            for _ in 0..<80 {
                await rig.run(50)
                if let shown = mode.shown { seen.insert(shown) }
            }
            await change.value
            #expect(mode.change?.result == .applied)
            #expect(mode.shown == "self_consumption")
            #expect(mode.doubt == nil)
            // Never back to the old mode on the way.
            #expect(seen == ["self_consumption"])
        }
    }

    /// A tap while the session is not streaming waits for it, says so, and
    /// sends once it is up: nothing goes into a gap.
    @MainActor
    @Test func aTapWaitsForTheStream() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = DemoRig()
            rig.app.startDemo()
            let mode = try #require(rig.app.home).nodes.mode
            let box = try #require(rig.box)
            #expect(!mode.connected)
            let change = Task { await mode.set("self_consumption") }
            await rig.run(0)
            #expect(mode.change?.waiting == true)
            #expect(mode.outcome?.text == "Waiting for the connection…")
            #expect(!box.receivedCommands.contains(Contract.opSetMode))
            await rig.run(3_000)
            await change.value
            #expect(box.receivedCommands.contains(Contract.opSetMode))
            #expect(mode.change?.result == .applied)
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

// MARK: The demo's balance

@Suite struct DemoBalanceTests {
    /// Core sends the house without the car: grid = house + battery +
    /// solar + car. The demo does the same on lane 0 and in /api/status, so
    /// Now never counts a charging car twice.
    @MainActor
    @Test func theHouseLeavesTheCarOut() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let box = try #require(rig.box)
        let site = try #require(rig.app.home).site
        box.house.plugIn()
        box.house.boostUntilMs = rig.scheduler.nowMs + 3_600_000
        await rig.run(3_000)
        let f = site.session.fields
        let ev = try #require(f[Contract.FID.evW])
        #expect(ev > 1_000)
        let grid = try #require(f[Contract.FID.gridW])
        let house = try #require(f[Contract.FID.loadW])
        let battery = f[Contract.FID.batteryW] ?? 0
        let solar = f[Contract.FID.pvW] ?? 0
        #expect(abs(grid - (house + battery + solar + ev)) <= 1)
        #expect(house == box.house.baseLoadW)
        // The house node shows the house, not the house and the car.
        let readings = NowFlow.readings(fields: f, freshness: { _ in NodeFreshness(carrier: .relay, srcState: .live, ageMs: 0, sourceName: nil) }, hasCar: true)
        #expect(readings.first { $0.node == .home }?.watts == house)
        #expect(readings.first { $0.node == .car }?.watts == ev)
    }
}

// MARK: Words

@Suite struct NodeWordsTests {
    @Test func timelineNamesTheReturnedHistoryResolution() {
        AppWords.$language.withValue(.en) {
            #expect(NodeWords.timelineMaterial(sampleMs: 300_000, planned: false) == "History: closed 5-minute means · live: source readings · dashed: forecast")
            #expect(NodeWords.timelineMaterial(sampleMs: 3_600_000, planned: true) == "History: closed 1-hour means · live: source readings · future bars: plan")
            #expect(NodeWords.timelineMaterial(sampleMs: 7_200_000, planned: false) == "History: closed 2-hour means · live: source readings · dashed: forecast")
        }
        AppWords.$language.withValue(.sv) {
            #expect(NodeWords.timelineMaterial(sampleMs: 1_800_000, planned: false) == "Historik: avslutade 30-minutersmedel · live: källvärden · streckat: prognos")
        }
    }

    /// Every sentence Now and the nodes' views hand to `L`, `NodeWords` or
    /// `AppWords` has a Swedish entry. Read from the source, so a new
    /// sentence cannot slip through.
    @Test func everySentenceHasSwedish() throws {
        let files = [
            "appleApp/FTW/UI/NowView.swift", "appleApp/FTW/UI/FlowDiagram.swift", "appleApp/FTW/UI/NodeView.swift",
            "appleApp/FTW/UI/NodeHistory.swift", "appleApp/FTW/UI/ModeSheet.swift",
            "appleApp/FTW/UI/PlanStrip.swift", "appleApp/FTW/UI/PlanView.swift", "appleApp/FTWKit/Sources/FTWKit/State/PlanShare.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/EnergyNode.swift", "appleApp/FTWKit/Sources/FTWKit/State/NowFlow.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/ModeModel.swift", "appleApp/FTWKit/Sources/FTWKit/State/PlanModel.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/HistoryModel.swift", "appleApp/FTW/UI/PairView.swift", "appleApp/FTW/UI/NodeTimeline.swift",
            "appleApp/FTW/UI/RootView.swift", "appleApp/FTWKit/Sources/FTWKit/State/PairModel.swift",
            "appleApp/FTW/Car/CarView.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/ChartWords.swift", "appleApp/FTW/UI/PriceView.swift",
            "appleApp/FTW/UI/StatusLine.swift", "appleApp/FTW/UI/ControlSheet.swift", "appleApp/FTW/UI/ModeMenu.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/StatusLine.swift",
            "appleApp/FTWKit/Sources/FTWKit/State/GridPhases.swift", "appleApp/FTW/UI/GridPhasesRow.swift",
            "appleApp/FTW/UI/HistoryTab.swift", "appleApp/FTW/UI/HomeTab.swift", "appleApp/FTWKit/Sources/FTWKit/State/HomeTab.swift",
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

// MARK: The plan for the widget

@MainActor
@Suite struct PlanShareTests {
    let scheduler = ManualScheduler(nowMs: CarTextTests.t)
    let shared = AppGroupFiles(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ftw-plan-\(UUID().uuidString)"))

    func run(_ ms: Double, step: Double = 20) async {
        var left = ms
        while left > 0 {
            for _ in 0..<10 { await Task.yield() }
            scheduler.advance(min(step, left))
            left -= step
        }
        for _ in 0..<10 { await Task.yield() }
    }

    /// The record carries when the box sent the plan, is written again only
    /// when the plan or what hangs on it changes or the box confirms it, and
    /// holds the car's windows and goal beside the battery.
    @Test func thePlanIsLeftForTheWidgetDatedByTheBox() async throws {
        let wakes = Counter()
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: nil, shared: shared)
        site.sharedWritten = { wakes.count += 1 }
        site.start()
        let loadpoints = LoadpointsModel(site: site, charging: nil, cache: nil)
        let prices = PriceModel(site: site)
        let plan = PlanModel(site: site)
        let share = PlanShare(site: site, plan: plan, loadpoints: loadpoints, prices: prices)
        site.connect(SimulatedBox.loopback(scheduler))
        loadpoints.activate()
        prices.activate()
        await run(2_000)
        // Nothing written before the box has sent a plan.
        #expect(shared.siteIDs(PlanEntry.self).isEmpty)

        plan.activate()
        await run(1_500)
        let sent = try #require(plan.receivedAtMs)
        let first = try #require(CacheReader(sources: [shared]).read(PlanEntry.self, siteId: "home"))
        #expect(first.record.readAtMs == sent)
        #expect(first.carrier == .cache)
        #expect(first.srcState == .live)
        #expect(first.value.battery?.isEmpty == false)
        #expect(!first.value.prices.isEmpty)
        // The demo car charges tonight toward its goal of 80 %.
        let charge = try #require(first.value.charges.first)
        #expect(charge.targetPct == 80)
        #expect(charge.toMs > charge.fromMs)
        #expect(first.value == share.entry.trimmed(nowMs: site.nowMs))
        let writes = wakes.count

        // The clock moving on rewrites nothing.
        await run(30_000, step: 250)
        #expect(wakes.count == writes)

        // The box confirming its plan dates the record anew.
        let confirm = Task { try await plan.load() }
        await run(500)
        try await confirm.value
        await run(100)
        let again = try #require(CacheReader(sources: [shared]).read(PlanEntry.self, siteId: "home"))
        #expect(again.record.readAtMs > first.record.readAtMs)
        #expect(wakes.count == writes + 1)
        plan.deactivate()
    }
}

// MARK: Tabs and History's day

@Suite struct HomeTabTests {
    /// The tab bar reads Now, Plan, History, Home, and Swedish says Hem
    /// for the tab where Now says Hemmet for the node.
    @Test func theTabsInBothLanguages() {
        #expect(HomeTab.allCases == [.now, .plan, .history, .home])
        AppWords.$language.withValue(.en) {
            #expect(HomeTab.allCases.map(\.title) == ["Now", "Plan", "History", "Home"])
        }
        AppWords.$language.withValue(.sv) {
            #expect(HomeTab.allCases.map(\.title) == ["Nu", "Plan", "Historik", "Hem"])
            #expect(EnergyNode.home.title != HomeTab.home.title)
        }
    }

    /// The goal the car's ring marks: its level, none when the goal is the
    /// car's own limit, and words for the mark beside the origin.
    @Test func theCarsGoalOnItsRing() {
        var s = Loadpoint.Schedule(socPct: 80, timeOfDayMinUTC: 300, clockMin: 420, surplusUnlockPct: 0, recurring: true, days: 0, finishAtVehicleLimit: false)
        #expect(CarText.goalPct(s) == 80)
        s.socPct = 140
        #expect(CarText.goalPct(s) == 100)
        s.finishAtVehicleLimit = true
        #expect(CarText.goalPct(s) == nil)
        AppWords.$language.withValue(.en) {
            #expect(CarText.originAndGoal("assumed at plug-in", goalPct: 80) == "assumed at plug-in · goal 80\u{00A0}%")
            #expect(CarText.originAndGoal("from the car", goalPct: nil) == "from the car")
        }
        AppWords.$language.withValue(.sv) {
            #expect(CarText.originAndGoal("antaget vid inkoppling", goalPct: 80) == "antaget vid inkoppling · mål 80\u{00A0}%")
        }
    }

    /// A day the phone has not been told is not zero: nothing since
    /// midnight and the answer on its way, or never asked, gives nothing;
    /// once the box has answered, its holes are what it recorded.
    @Test func aDayNotToldIsNotZero() {
        let step = 300_000.0
        func day(_ watts: Double?, fetching: Bool) -> [HistorySample] {
            (0..<12).map { HistorySample(startMs: Double($0) * step, stepMs: step, watts: watts, fetching: fetching) }
        }
        #expect(HistoryModel.told(day(nil, fetching: true), fromMs: 0, answered: false) == nil)
        #expect(HistoryModel.told(day(nil, fetching: false), fromMs: 0, answered: false) == nil)
        #expect(HistoryModel.told(day(nil, fetching: true), fromMs: 0, answered: true) == nil)
        #expect(HistoryModel.told([], fromMs: 0, answered: true) == nil)
        let empty = HistoryModel.told(day(nil, fetching: false), fromMs: 0, answered: true)
        #expect(empty?.inWh == 0)
        #expect(empty?.missingMs == 12 * step)
        // Something told: its sum, and a tile on its way is not missing.
        var some = day(nil, fetching: true)
        some[0] = HistorySample(startMs: 0, stepMs: step, watts: 1_200)
        let partial = HistoryModel.told(some, fromMs: 0, answered: false)
        #expect(partial?.inWh == 100)
        #expect(partial?.missingMs == 0)
    }

    /// Each row says what its node did, in both directions where power
    /// runs both ways, and a gap only once it is ten minutes.
    @Test func aDayInEachNodesWords() {
        let e = EnergyToday(inWh: 5_000, outWh: 4_200, missingMs: 0)
        AppWords.$language.withValue(.en) {
            #expect(DayWords.line(.solar, e) == "Made 5.0\u{00A0}kWh")
            #expect(DayWords.line(.battery, e) == "Charged 5.0\u{00A0}kWh · gave 4.2\u{00A0}kWh")
            #expect(DayWords.line(.grid, e) == "Bought 5.0\u{00A0}kWh · sold 4.2\u{00A0}kWh")
            #expect(DayWords.line(.home, e) == "Used 5.0\u{00A0}kWh")
            #expect(DayWords.car(wh: 33_000) == "Charged 33\u{00A0}kWh")
            #expect(DayWords.missing(e) == nil)
            #expect(DayWords.missing(EnergyToday(inWh: 0, outWh: 0, missingMs: 540_000)) == nil)
            #expect(DayWords.missing(EnergyToday(inWh: 0, outWh: 0, missingMs: 2_400_000)) == "40 min not recorded")
        }
        AppWords.$language.withValue(.sv) {
            #expect(DayWords.line(.battery, e) == "Laddat 5,0\u{00A0}kWh · gett 4,2\u{00A0}kWh")
            #expect(DayWords.shape(.solar) == "Producerat 0,0\u{00A0}kWh")
        }
    }
}
