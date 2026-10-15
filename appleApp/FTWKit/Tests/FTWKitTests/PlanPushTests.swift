import Foundation
import Testing
@testable import FTWKit
import FTWDemo

/// The plan reaches the car the moment the box replans. A box that pushes
/// its plan redraws each car from the push; an older box is read once when
/// FTW Cloud says a cable went in, each quarter while a car is plugged in,
/// and every 15 s while it says the plan is being made.
@MainActor
@Suite struct PlanPushTests {
    typealias Rig = CarFlowTests.Rig

    func reads(_ box: SimulatedBox) -> Int { box.receivedRequests.filter { $0 == "GET /api/loadpoints" }.count }

    /// The bytes srcfl/ftw pins in TestThePlanWithChargersVector.
    @Test func thePlanWithChargersDecodesFromTheBoxsBytes() throws {
        let hex = "a6637265760765736c6f747381a765677269645719012c66726561736f6e70657870656e736976655f696d706f72746773746172744d731b000001a131ea48806862617474657279573904af6a6475726174696f6e4d731a000dbba06a70726963654d696e6f7218576b736f635065726d696c6c65190280657374616c65f4686365696c696e6757f668636861726765727382a76269646565617365656770656e64696e67f467746f74616c5768191ce86777696e646f777381a3627768191ce865656e644d731b000001a1325825806773746172744d731b000001a131ea4880686f75746461746564f469706c7567676564496ef56b73686f727466616c6c57681904b0a762696466676172616765656361724964782030313233343536373839616263646566303132333435363738396162636465666770656e64696e67f567746f74616c5768006777696e646f777380686f75746461746564f569706c7567676564496ef468757074696d654d731a0036ee80"
        let plan = Plan(try decodeCBOR(Bytes(hex: hex)))
        #expect(plan.rev == 7)
        #expect(plan.slots.first?.socPermille == 640)
        let chargers = try #require(plan.chargers)
        #expect(chargers == [
            PlanCharger(id: "easee", pluggedIn: true, windows: [Loadpoint.Window(fromMs: 1_791_838_800_000, toMs: 1_791_846_000_000, peakW: nil, energyWh: 7_400)], totalWh: 7_400, shortfallWh: 1_200),
            PlanCharger(id: "garage", carId: "0123456789abcdef0123456789abcdef", pluggedIn: false, pending: true, outdated: true, windows: [], totalWh: 0),
        ])
        // A plan from a box without chargers says so with nil, not an empty
        // list.
        #expect(Plan(Plan(rev: 1, uptimeMs: 0, slots: [], stale: false, ceilingW: nil).wire).chargers == nil)
        #expect(Plan(plan.wire) == plan)
    }

    @Test func aPushedPlanMovesTheCarsWindowsWithoutARead() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        home.loadpoints.activate()
        await rig.run(1_500)
        #expect(reads(box) == 1)
        let before = try #require(home.loadpoints.windows["garage"]?.first)

        // The goal moves on the box: it replans and pushes the plan.
        box.house.schedule = (0.95, 7 * 60, true, 0b0011111, 0)
        box.replan()
        await rig.run(1_000)
        let after = try #require(home.loadpoints.windows["garage"]?.first)
        #expect(after.toMs > before.toMs)
        #expect(reads(box) == 1)
        let car = try #require(home.loadpoints.points.first)
        #expect(car.planWindows == [after])
        #expect(!car.planPending)
        #expect(home.loadpoints.shortfallWh["garage"] != nil)
        // Now's strip, the plan view and the watch draw from PlanShare.
        #expect(home.nodes.planShare.entry.charges.first?.toMs == after.toMs)
        #expect(home.nodes.plan.plan?.rev == home.site.session.plan?.rev)

        // Nothing reads the car again while the plan holds.
        await rig.run(60_000, step: 500)
        #expect(reads(box) == 1)
    }

    /// A cable plugged in arrives on the pushed plan: the windows at once,
    /// and one read for the rest of the car.
    @Test func aPlugInOnThePushIsReadOnceForTheRestOfTheCar() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        box.setCarPluggedIn(false)
        await rig.run(1_000)
        home.loadpoints.activate()
        await rig.run(1_500)
        #expect(reads(box) == 1)
        #expect(home.loadpoints.points.first?.pluggedIn == false)

        box.setCarPluggedIn(true)
        // The replan takes 300 ms and the loopback 120 ms: the push has
        // landed, and the read it asks for has not reached the box yet.
        await rig.run(450)
        #expect(reads(box) == 1)
        #expect(home.loadpoints.points.first?.pluggedIn == true)
        #expect(home.loadpoints.windows["garage"]?.isEmpty == false)
        await rig.run(1_500)
        #expect(reads(box) == 2)
        await rig.run(60_000, step: 500)
        #expect(reads(box) == 2)
    }

    /// An older box pushes nothing. FTW Cloud's copy says the cable went in,
    /// and that is one read, which brings the plan.
    @Test func anOldBoxIsReadOnceWhenFTWCloudSaysTheCableWentIn() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        box.pushesPlan = false
        box.setCarPluggedIn(false)
        await rig.run(1_000)
        home.loadpoints.activate()
        await rig.run(1_500)
        #expect(reads(box) == 1)

        box.setCarPluggedIn(true)
        await rig.run(1_000)
        #expect(reads(box) == 1)
        #expect(home.loadpoints.points.first?.pluggedIn == false)

        let car = CarEntry.Car(loadpointID: "garage", pluggedIn: true, socPct: 20, socSource: "assumed", socReadAtMs: nil, powerW: 0, targetSocPct: 80)
        home.site.cloudCars = Stamped([car], asOfMs: rig.scheduler.nowMs, origin: .cloud)
        await rig.run(1_500)
        #expect(reads(box) == 2)
        #expect(home.loadpoints.points.first?.pluggedIn == true)
        #expect(home.loadpoints.windows["garage"]?.isEmpty == false)
        #expect(home.nodes.planShare.entry.charges.isEmpty == false)

        // The same cable again is no news.
        home.site.cloudCars = Stamped([car], asOfMs: rig.scheduler.nowMs, origin: .cloud)
        await rig.run(60_000, step: 500)
        #expect(reads(box) == 2)
    }

    /// An older box that says its plan is being made is asked again about
    /// every 15 s, and no longer once the plan is there.
    @Test func anOldBoxMakingItsPlanIsAskedEvery15s() async throws {
        let rig = Rig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        let box = try #require(rig.box)
        box.pushesPlan = false
        box.replanMs = 40_000
        // Now asks for the plan, which comes without chargers: an older box.
        home.nodes.plan.activate()
        home.loadpoints.activate()
        await rig.run(2_000)
        #expect(home.site.session.plan != nil)
        #expect(home.site.session.plan?.chargers == nil)

        box.house.schedule = (0.95, 7 * 60, true, 0b0011111, 0)
        box.replan()
        home.loadpoints.reread()
        await rig.run(1_000)
        #expect(home.loadpoints.points.first?.planPending == true)
        let pending = reads(box)
        await rig.run(30_000, step: 250)
        #expect(reads(box) - pending >= 2)
        #expect(reads(box) - pending <= 3)

        // The plan is made at 40 s: the next ask finds it, and that is all.
        await rig.run(16_000, step: 250)
        #expect(home.loadpoints.points.first?.planPending == false)
        #expect(home.loadpoints.windows["garage"]?.isEmpty == false)
        let done = reads(box)
        await rig.run(60_000, step: 500)
        #expect(reads(box) <= done + 1)
    }
}
