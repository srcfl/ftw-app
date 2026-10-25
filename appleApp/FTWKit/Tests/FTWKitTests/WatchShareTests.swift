import Foundation
import Testing
@testable import FTWKit
import FTWDemo
import FTWShared

/// The Apple Watch through this phone, against the simulated box: the
/// records it is handed, and its commands from tap to the box's answer.
@MainActor
@Suite struct WatchShareTests {
    typealias Rig = RemoteTests.Rig

    /// Run a watch command the way the bridge does, keeping every step.
    func run(_ op: WatchCommand.Op, _ rig: Rig, home: String = "demo", id: String? = nil, sentAtMs: Double? = nil, for ms: Double = 6_000) async throws -> (end: WatchReceipt, steps: [WatchReceipt]) {
        let homeModels = try #require(rig.app.home)
        let c = WatchCommand(id: id, op: op, home: home, sentAtMs: sentAtMs ?? rig.scheduler.nowMs)
        var steps = [WatchReceipt]()
        let task = Task { await WatchShare.run(c, home: homeModels, nowMs: rig.scheduler.nowMs) { steps.append($0) } }
        await rig.run(ms)
        return (await task.value, steps)
    }

    /// The box gets the watch's own `cmdId`, and the receipt moves sent,
    /// accepted, confirmed: CONFIRMED only once the box's result says so.
    @Test func chargeNowFromTheWatchCarriesItsIdAndTheBoxsReceipt() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            _ = try rig.start()
            let id = WatchCommand.newID(nowMs: rig.scheduler.nowMs)
            let (end, steps) = try await run(.chargeNow(loadpointID: "garage"), rig, id: id)
            let cmd = try #require(rig.wire?.commands.last)
            #expect(cmd.cmdId == id)
            #expect(cmd.op == Contract.opLoadpointHold)
            #expect(end.confirmed == .done && end.tone == .done && end.commandID == id)
            // In order, and never confirmed before the box's result.
            let confirmedAt = try #require(steps.firstIndex { $0.confirmed == .done })
            let acceptedAt = try #require(steps.firstIndex { $0.accepted == .done })
            #expect(acceptedAt < confirmedAt)
            #expect(steps.prefix(confirmedAt).allSatisfy { $0.confirmed != .done && $0.tone == .working })
            #expect(steps.allSatisfy { $0.commandID == id })
        }
    }

    @Test func aCommandForAnotherHomeOrTooLateSendsNothing() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            _ = try rig.start()
            let other = try await run(.chargeNow(loadpointID: "garage"), rig, home: "s9", for: 500)
            #expect(other.end.tone == .failed && other.end.sent == .failed)
            #expect(other.end.text == WatchWord.otherHome.text)
            let late = try await run(.pause(loadpointID: "garage"), rig, sentAtMs: rig.scheduler.nowMs - WatchCommand.lifeMs - 1, for: 500)
            #expect(late.end.text == WatchWord.tooLate.text)
            let odd = try await run(.pause(loadpointID: "garage"), rig, id: UUID().uuidString, for: 500)
            #expect(odd.end.tone == .failed)
            #expect(rig.wire?.commands.isEmpty ?? true)
        }
    }

    @Test func pauseAndBackToThePlanFromTheWatch() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            _ = try rig.start()
            let pause = try await run(.pause(loadpointID: "garage"), rig)
            #expect(pause.end.confirmed == .done)
            #expect(rig.wire?.commands.last?.args["power_w"]?.double == 0)
            let back = try await run(.backToPlan(loadpointID: "garage"), rig)
            #expect(back.end.confirmed == .done)
            #expect(rig.wire?.commands.last?.args["clear"]?.bool == true)
        }
    }

    /// The mode changes in Plan on the iPhone alone. A watch that still
    /// asks, an older build, is told where, and nothing goes to the box.
    @Test func theModeFromAWatchIsChangedInPlan() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            _ = try rig.start()
            await rig.run(2_000)
            let home = try #require(rig.app.home)
            let modes = try #require(WatchShare.context(home, isDemo: true, nowMs: rig.scheduler.nowMs).modes)
            let manual = try #require(modes.modes.first { !$0.isPlan && $0.key != modes.shown })
            let (end, _) = try await run(.mode(manual.key), rig)
            #expect(end.text == WatchWord.modeInPlan.text)
            #expect(end.sent == .failed && end.tone == .failed)
            #expect(WatchShare.answerAtOnce(WatchCommand(op: .mode(manual.key), home: "s1", sentAtMs: 0)) != nil)
            #expect(WatchShare.answerAtOnce(WatchCommand(op: .pause(loadpointID: "lp1"), home: "s1", sentAtMs: 0)) == nil)
            #expect(rig.wire?.commands.contains { $0.op == Contract.opSetMode } != true)
        }
    }

    /// The demo's records, dated, and none of them claiming to be the cache
    /// while the stream is live; Now's figures as the phone holds them.
    @Test func theContextHoldsTheRecordsTheWidgetsWouldRead() async throws {
        let rig = Rig()
        _ = try rig.start()
        let home = try #require(rig.app.home)
        let done = WatchShare.looking(home)
        defer { done() }
        await rig.run(6_000)
        let ctx = WatchShare.context(home, isDemo: true, nowMs: rig.scheduler.nowMs)
        #expect(ctx.home == "demo" && ctx.isDemo)
        let now = try #require(ctx.now)
        #expect(now.carrier != .cache)
        #expect(now.value.readings.contains { $0.node == .battery && $0.levelPct != nil })
        #expect(ctx.cars?.value.cars.first?.loadpointID == "garage")
        #expect(ctx.prices != nil)
        #expect(ctx.modes?.mayControl == true)
        // Packs small enough to hand over.
        #expect(try ctx.packed().count < 40_000)
        #expect(WatchShare.context(nil, isDemo: false, nowMs: 0).hasHome == false)
    }

    /// The reply to a look carries the last three minutes the phone
    /// recorded of each node, in one message the size the watch allows.
    @Test func theReplyToALookCarriesTheLastThreeMinutes() async throws {
        let rig = Rig()
        _ = try rig.start()
        let home = try #require(rig.app.home)
        await rig.run(200_000, step: 1_000)
        let now = rig.scheduler.nowMs
        let recent = WatchShare.recent(home, nowMs: now)
        #expect(recent.wireBytes <= WatchRecent.maxBytes)
        let nodes = Set(recent.lanes.map(\.node))
        #expect(nodes.isSuperset(of: [.home, .battery, .grid]))
        let usage = recent.samples(.home)
        // About one reading a second, across the whole window and no more.
        #expect(usage.count >= 150 && usage.count <= 200)
        #expect((usage.first?.t ?? 0) >= now - WatchRecent.windowMs)
        #expect(now - (usage.last?.t ?? 0) < 3_000)
        // Solar as what it makes, as the watch's figures say it.
        #expect(recent.samples(.solar).allSatisfy { $0.v >= 0 })
        #expect(usage.allSatisfy { !$0.seen })
    }

    /// While the watch looks, the plan is read with its forecast, so the
    /// dial has its sun without the phone's plan view ever opening.
    @Test func aLookingWatchGetsTheSun() async throws {
        let rig = Rig()
        _ = try rig.start()
        let home = try #require(rig.app.home)
        let done = WatchShare.looking(home)
        defer { done() }
        await rig.run(10_000)
        #expect(home.nodes.plan.forecastStamp != nil)
        let ctx = WatchShare.context(home, isDemo: true, nowMs: rig.scheduler.nowMs)
        #expect(ctx.plan?.value.daylight != nil)
    }

    /// No home on the phone says why: a sign-out the watch forgets, or a
    /// phone still opening the home the watch keeps.
    @Test func noHomeSaysWhy() {
        let out = WatchShare.context(nil, isDemo: false, signedOut: true, nowMs: 1)
        let opening = WatchShare.context(nil, isDemo: false, nowMs: 1)
        #expect(out.signedOut == true && !out.hasHome)
        #expect(opening.signedOut == nil && !opening.hasHome)
        let kept = WatchContext(home: "s1", isDemo: false, sentAtMs: 0)
        #expect(WatchContext.merging(opening, over: kept) == kept)
        #expect(WatchContext.merging(out, over: kept)?.hasHome == false)
    }

    /// A watch looking through a phone locked in a pocket gets Now at 1 Hz,
    /// not the 0.2 Hz a hidden app asks for; the phone going to the
    /// background meanwhile closes nothing; the end of the look lets the
    /// phone rest again.
    @Test func aLookingWatchKeepsTheStreamAtOneHertz() async throws {
        let rig = Rig()
        _ = try rig.start()
        let home = try #require(rig.app.home)
        let site = home.site
        final class Frames { var at = Set<Double>() }
        func frames(over ms: Double) async -> Int {
            let seen = Frames()
            let token = site.observe { if let t = site.lastFrameAtMs { seen.at.insert(t) } }
            await rig.run(ms)
            site.unobserve(token)
            return seen.at.count
        }
        await rig.run(3_000)
        rig.app.setVisible(false)
        rig.app.suspend()
        await rig.run(6_000)
        #expect(await frames(over: 20_000) <= 6)

        let done = WatchShare.looking(home)
        #expect(site.documentVisible && site.watched)
        await rig.run(3_000)
        #expect(await frames(over: 20_000) >= 17)
        rig.app.setVisible(false)
        rig.app.suspend()
        #expect(site.documentVisible)
        #expect(await frames(over: 10_000) >= 8)
        // The phone's word for how long a reading stands goes with it.
        #expect(WatchShare.now(home)?.value.standsMs == LiveTrace.gapMs)

        done()
        #expect(!site.documentVisible && !site.watched)
        await rig.run(6_000)
        #expect(await frames(over: 20_000) <= 6)
    }

    /// Through FTW Cloud frames come up to five a second. The watch hears
    /// one when what it shows moves, and otherwise once a second.
    @Test func theWatchHearsAMoveAtOnceAndOtherwiseOnceASecond() {
        func now(_ watts: Double, at t: Double, live: Bool = true) -> CacheRecord<WatchNow> {
            CacheRecord(siteId: "s", carrier: .tunnel, srcState: .live, readAtMs: t,
                        value: WatchNow(readings: [.init(node: .grid, watts: watts, way: .buying, live: live)], control: .inControl))
        }
        let last = now(1_234, at: 10_000)
        // 1.2 kW either way: nothing the wrist shows moved.
        #expect(!WatchShare.worthSending(now(1_236, at: 10_200), after: last))
        #expect(WatchShare.worthSending(now(1_236, at: 11_000), after: last))
        // 1.7 kW: a move goes at once.
        #expect(WatchShare.worthSending(now(1_650, at: 10_200), after: last))
        // The glow going out is a move too.
        #expect(WatchShare.worthSending(now(1_234, at: 10_200, live: false), after: last))
        #expect(!WatchShare.worthSending(now(1_650, at: 9_000), after: last))
        #expect(WatchShare.worthSending(last, after: nil))
    }

}
