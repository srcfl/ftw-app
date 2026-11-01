import Foundation
import Testing
@testable import FTWKit
import FTWDemo

@Suite struct HouseholdClockTests {
    let owner: Set<String> = ["ftw.live.read", "ftw.setup.write"]

    @Test func aBoxOnUTCIsOfferedThePhonesZone() {
        #expect(HouseholdClock.zoneToOffer(boxTZ: "UTC", phoneTZ: "Europe/Stockholm", scopes: owner) == "Europe/Stockholm")
        #expect(HouseholdClock.zoneToOffer(boxTZ: "Etc/UTC", phoneTZ: "Europe/Stockholm", scopes: owner) == "Europe/Stockholm")
    }

    @Test func aBoxWithAZoneOfItsOwnIsOfferedNothing() {
        #expect(HouseholdClock.zoneToOffer(boxTZ: "Europe/Stockholm", phoneTZ: "America/New_York", scopes: owner) == nil)
    }

    @Test func aPhoneOnUTCOrWithoutSetupOffersNothing() {
        #expect(HouseholdClock.zoneToOffer(boxTZ: "UTC", phoneTZ: "GMT", scopes: owner) == nil)
        #expect(HouseholdClock.zoneToOffer(boxTZ: "UTC", phoneTZ: nil, scopes: owner) == nil)
        #expect(HouseholdClock.zoneToOffer(boxTZ: "UTC", phoneTZ: "Europe/Stockholm", scopes: ["ftw.live.read"]) == nil)
    }
}

/// Erik's box (31 October 2026): Docker on UTC, so 17:00 was met at 18:00.
@MainActor
@Suite struct HouseholdClockFlowTests {
    func start(boxZone: TimeZone) throws -> (AppModel, SimulatedBox, ManualScheduler) {
        let scheduler = ManualScheduler(nowMs: CarTextTests.t)
        var made: SimulatedBox?
        let app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { s in
            let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: boxZone))
            made = box
            return LoopbackCarrier(box: box, scheduler: s)
        })
        app.startDemo()
        let site = try #require(app.site)
        site.phoneTimeZone = { "Europe/Stockholm" }
        return (app, try #require(made), scheduler)
    }

    /// Runs the clock for `ms`, or until `done` holds.
    func run(_ scheduler: ManualScheduler, _ ms: Double, until done: () -> Bool = { false }) async {
        var left = ms
        while left > 0, !done() {
            for _ in 0..<10 { await Task.yield() }
            scheduler.advance(min(50, left))
            left -= 50
        }
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aBoxOnUTCTakesThePhonesZoneOnce() async throws {
        let (app, box, scheduler) = try start(boxZone: TimeZone(identifier: "UTC")!)
        defer { withExtendedLifetime(app) {} }
        await run(scheduler, 2_000) { box.house.timeZone.identifier == "Europe/Stockholm" }
        await run(scheduler, 2_000)
        #expect(box.receivedCommands.filter { $0 == Contract.opSiteTimeZonePropose }.count == 1)
        #expect(box.house.timeZone.identifier == "Europe/Stockholm")
    }

    @Test func aBoxThatKeepsAZoneIsNotOfferedOne() async throws {
        let (app, box, scheduler) = try start(boxZone: CarTextTests.stockholm)
        defer { withExtendedLifetime(app) {} }
        await run(scheduler, 2_000) { box.receivedCommands.contains(Contract.opSiteTimeZonePropose) }
        #expect(!box.receivedCommands.contains(Contract.opSiteTimeZonePropose))
    }
}
