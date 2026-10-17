import Foundation
import Testing
@testable import FTWKit
import FTWDemo
import FTWShared

/// The car as its own entity (docs/cars.md in srcfl/ftw): the names come
/// from the registry, the level is the car's own and says how old it is,
/// and a box without `der.car` keeps the charger as the car.
@Suite struct CarWireTests {
    @Test func theCarNamesAreTheRegistrys() {
        #expect(CarField.allCases.map(\.rawValue) == Contract.carFields)
        #expect(ChargerCarField.allCases.map(\.rawValue) == Contract.chargerCarFields)
        #expect(CarSocSource.allCases.map(\.rawValue) == Contract.carSocSources)
        #expect(CarIdentifiedBy.allCases.map(\.rawValue) == Contract.carIdentifiedBy)
        #expect(Contract.scopes.contains(Contract.scopeCarsWrite))
        // The box spells each one in snake_case on its HTTP routes.
        #expect(CarField.socPermille.http == "soc_permille")
        #expect(CarField.goalReadyByMin.http == "ready_by_min")
        #expect(CarField.goalReadyByMin.wire == "readyByMin")
        #expect(ChargerCarField.carIdentifiedBy.http == "car_identified_by")
    }

    /// Fredrik's box on 17 October 2026, its VIN left out: the Tesla, an
    /// hour old from Home Assistant, with nothing delivered since.
    static let homeBox = """
    {"cars":[{"id":"264348898b35373ce3d9c9473fae9704","box_minted":true,"name":"Car 1","make":"Tesla","capacity_wh":76000,
    "soc_permille":720,"soc_source":"vehicle","soc_age_s":4067,"energy_since_wh":0,"soc_estimate":false,"charge_limit_permille":800,
    "goal":{"target_permille":800,"ready_by_min":420,"days":127,"finish_at_limit":false},"surplus_only":false,"sources":["tesla-ha"]}],"removed":null}
    """

    @Test func theHomeBoxsCarReadsAsTheCarsOwnLevelAnHourOld() throws {
        try AppWords.$language.withValue(.en) {
            let wire = try JSON(parsing: Array(Self.homeBox.utf8))
            let car = try #require(wire["cars"]?.array?.first.flatMap(Car.init))
            #expect(car.id == "264348898b35373ce3d9c9473fae9704")
            #expect(car.boxMinted)
            #expect(car.shownName == "Car 1")
            #expect(car.capacityWh == 76_000)
            #expect(car.sources == ["tesla-ha"])
            #expect(car.goal == Car.Goal(targetPermille: 800, readyByMin: 420, days: 127, finishAtLimit: false))
            let read = CarTextTests.t
            let level = try #require(car.level(answeredAtMs: read))
            #expect(level.pct == 72)
            #expect(level.source == .vehicle)
            #expect(!level.estimate)
            #expect(level.atMs == read - 4_067_000)
            // Never fake live: an old reading says how old it is, and stays
            // the car's own while nothing has flowed.
            #expect(CarText.percent(level) == "72\u{00A0}%")
            #expect(CarText.origin(level, nowMs: read, zone: CarTextTests.stockholm) == "from the car · 1 h ago")
            #expect(CarText.origin(level, nowMs: read + 3 * 3_600_000, zone: CarTextTests.stockholm) == "from the car · 4 h ago")
            #expect(CarText.limit(car) == "Limit 80\u{00A0}%")
            #expect(level.asLevel(nowMs: read).origin == .carEarlier)
            #expect(level.legacySource == "vehicle")
        }
    }

    @Test func anEstimateSaysWhatFlowedSinceTheReading() throws {
        try AppWords.$language.withValue(.en) {
            let zone = CarTextTests.stockholm
            let read = CarTextTests.t
            let at = read - 2 * 3_600_000
            var car = Car(id: Car.mintID(), name: "", make: "Tesla", socPermille: 220, socSource: "vehicle", socAgeS: (read - at) / 1000, energySinceWh: 6_000, socEstimate: true)
            let level = try #require(car.level(answeredAtMs: read))
            #expect(CarText.percent(level) == "≈\u{00A0}22\u{00A0}%")
            #expect(CarText.origin(level, nowMs: read, zone: zone) == "from the car \(AppWords.clock(at, zone: zone)) + 6.0\u{00A0}kWh")
            #expect(level.asLevel(nowMs: read).origin == .estimated)
            #expect(level.legacySource == "inferred")
            #expect(car.shownName == "Tesla")

            car.socSource = "assumed"
            car.socAgeS = nil
            let assumed = try #require(car.level(answeredAtMs: read))
            #expect(assumed.estimate && assumed.atMs == nil)
            #expect(CarText.origin(assumed, nowMs: read, zone: zone) == "assumed at plug-in")
            #expect(assumed.legacySource == "assumed")

            car.socSource = "manual"
            car.socEstimate = false
            car.socAgeS = 20 * 60
            car.energySinceWh = 0
            let set = try #require(car.level(answeredAtMs: read))
            #expect(CarText.origin(set, nowMs: read, zone: zone) == "set by hand · 20 min ago")
            #expect(set.asLevel(nowMs: read).origin == .you)

            car.socPermille = nil
            #expect(car.level(answeredAtMs: read) == nil)
        }
    }

    @Test func aChargerNamesItsCarAndTheResultCarriesIt() throws {
        let json = """
        {"id":"easee","driver_name":"easee","plugged_in":true,"max_charge_w":11000,"session":"s9","car_identified_by":"asking",
        "choose":["6f1d2a3b4c5d6e7f8091a2b3c4d5e6f7","0a1b2c3d4e5f60718293a4b5c6d7e8f9"],"soc_source":"unknown"}
        """
        let lp = Loadpoint(try JSON(parsing: Array(json.utf8)))
        let c = try #require(lp.chargerCar)
        #expect(c.asking && c.carID.isEmpty && c.session == "s9")
        #expect(c.choose.count == 2)
        #expect(lp.socPct == nil)
        AppWords.$language.withValue(.en) {
            #expect(CarText.charger(lp) == "On Easee · 11\u{00A0}kW max")
        }
        // Nothing plugged in names no car, whatever the fields say.
        let out = Loadpoint(try JSON(parsing: Array(#"{"id":"easee","plugged_in":false,"car_id":"x"}"#.utf8)))
        #expect(out.chargerCar == nil)

        let result = CmdResult(.map([
            ("cmdId", .text("c")), ("state", .text("applied")),
            ("car", .map([("id", .text(DemoCars.zoe)), ("socPermille", .int(450)), ("socSource", .text("manual")), ("socAgeS", .int(5)), ("energySinceWh", .int(0)), ("socEstimate", .bool(false)), ("surplusOnly", .bool(false))])),
            ("charger", .map([("session", .text("s9")), ("carId", .text(DemoCars.zoe)), ("carIdentifiedBy", .text("tap"))])),
        ]))
        #expect(result.car?.socPermille == 450)
        #expect(result.charger == ChargerCar(session: "s9", carID: DemoCars.zoe, identifiedBy: "tap"))
    }

    @Test func aMintedIDIsOneTheBoxTakes() {
        let id = Car.mintID()
        #expect(Car.isID(id))
        #expect(id != Car.mintID())
        #expect(!Car.isID("ABCDEF0123456789abcdef0123456789"))
        // A goal's days: once is 0, every day all seven.
        #expect(CarsModel.goalDays(recurring: false, days: 0b0011111) == 0)
        #expect(CarsModel.goalDays(recurring: true, days: 0) == 127)
        #expect(CarsModel.goalDays(recurring: true, days: 0b0011111) == 0b0011111)
    }
}

/// The car list against the demo box: a Core with cars, and one from before.
@MainActor
@Suite struct CarsFlowTests {
    @MainActor
    final class Rig {
        let scheduler: ManualScheduler
        var box: SimulatedBox?
        var app: AppModel!

        init(_ cars: DemoCars, car: DemoCar? = nil, nowMs: Double = CarTextTests.t) {
            scheduler = ManualScheduler(nowMs: nowMs)
            app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { [unowned self] s in
                let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
                box.resultDelayMs = 300
                car?.apply(to: box.house, nowMs: s.nowMs)
                cars.apply(to: box, nowMs: s.nowMs)
                self.box = box
                return LoopbackCarrier(box: box, scheduler: s)
            })
        }

        func start() throws -> (HomeModels, SimulatedBox) {
            app.startDemo()
            let home = try #require(app.home)
            home.loadpoints.activate()
            home.cars.activate()
            return (home, try #require(box))
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

        /// Run one command to its end on the manual clock.
        func settle(_ ms: Double = 3_000, _ work: @escaping @MainActor () async -> Void) async {
            let task = Task { @MainActor in await work() }
            await run(ms)
            await task.value
        }
    }

    func carReads(_ box: SimulatedBox) -> Int { box.receivedRequests.filter { $0 == "GET /api/cars" }.count }

    @Test func anOldBoxKeepsTheChargerAsTheCarAndIsNeverAskedForCars() async throws {
        let rig = Rig(.old)
        let (home, box) = try rig.start()
        await rig.run(2_000)
        #expect(!home.cars.keepsCars)
        #expect(carReads(box) == 0)
        #expect(home.cars.cars.isEmpty)
        let lp = try #require(home.loadpoints.points.first)
        #expect(lp.chargerCar == nil)
        // Today's view: the charger's level, as before.
        #expect(home.loadpoints.level(lp)?.origin == .assumed)
        #expect(home.loadpoints.level(lp)?.pct == 20)
        let entry = CarShare.entry(home.loadpoints.points, answeredAtMs: rig.scheduler.nowMs, level: { _ in nil }, cars: home.cars)
        #expect(entry.owned == nil && entry.asking == nil)
        #expect(entry.cars.first?.carID == nil)
    }

    /// The cable is out and the charger knows no car, yet the car shows
    /// with its last level and how old it is. Read once after hello, and
    /// not again while nothing moves.
    @Test func aCarWithTheCableOutShowsItsLastLevelAndAge() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig(.away)
            let (home, box) = try rig.start()
            await rig.run(2_000)
            #expect(home.cars.keepsCars)
            #expect(carReads(box) == 1)
            let car = try #require(home.cars.cars.first)
            #expect(car.shownName == "Model Y")
            #expect(home.cars.charger(of: car) == nil)
            #expect(home.loadpoints.points.first?.pluggedIn == false)
            let level = try #require(home.cars.level(car))
            #expect(level.pct == 72)
            #expect(CarText.origin(level, nowMs: rig.scheduler.nowMs, zone: CarTextTests.stockholm) == "from the car · 1 h ago")
            // The widgets and the watch get the car, plugged in or not.
            let entry = CarShare.entry(home.loadpoints.points, answeredAtMs: rig.scheduler.nowMs, level: { _ in nil }, cars: home.cars)
            #expect(entry.owned == [CarEntry.Owned(id: DemoCars.modelY, name: "Model Y", socPct: 72, socSource: "vehicle", socReadAtMs: level.atMs, socEstimate: false, targetSocPct: 80, loadpointID: nil)])
            #expect(entry.asking == [])
            // "Is the car ready?" says where the car stands, with its level.
            let answer = home.loadpoints.answer(locked: false)
            #expect(answer.gist == .unplugged)
            #expect(answer.details.contains("Model Y: 72\u{00A0}% · from the car · 1 h ago"))

            // No timer asks again.
            await rig.run(120_000, step: 1_000)
            #expect(carReads(box) == 1)
        }
    }

    @Test func theCarOnTheChargerShowsItsOwnLevelThere() async throws {
        let rig = Rig(.one, car: .car)
        let (home, box) = try rig.start()
        await rig.run(2_000)
        let lp = try #require(home.loadpoints.points.first)
        #expect(lp.chargerCar?.carID == DemoCars.modelY)
        #expect(lp.chargerCar?.by == .only)
        let car = try #require(home.cars.car(on: lp))
        #expect(home.cars.charger(of: car)?.id == "garage")
        #expect(home.cars.ordered.first?.id == car.id)
        #expect(home.cars.level(car)?.source == .vehicle)
        #expect(home.loadpoints.level(lp)?.pct == 64)
        #expect(home.loadpoints.level(lp)?.origin == .car)
        // The plan the box pushes when it replans names the car.
        box.replan()
        await rig.run(1_000)
        #expect(home.site.session.plan?.chargers?.first?.carId == DemoCars.modelY)
        let entry = CarShare.entry(home.loadpoints.points, answeredAtMs: rig.scheduler.nowMs, level: { _ in nil }, cars: home.cars)
        #expect(entry.cars.first?.carName == "Model Y")
        #expect(entry.cars.first?.socPct == 64)
        #expect(entry.owned?.first?.loadpointID == "garage")
        // Read once after hello; the first read of the chargers asks nothing
        // more, and nor does the replan's push of the same car.
        #expect(carReads(box) == 1)
    }

    /// Two cars and no answer: the charger asks, and one tap names the car.
    @Test func twoCarsWithNoAnswerAskAndOneTapNamesTheCar() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig(.asking)
            let (home, box) = try rig.start()
            await rig.run(2_000)
            let lp = try #require(home.cars.asking.first)
            #expect(home.cars.choices(lp).map(\.shownName) == ["Model Y", "Zoe"])
            #expect(home.cars.unnamed(lp))
            // An unnamed car's level is never a number.
            #expect(home.loadpoints.level(lp) == nil)
            let entry = CarShare.entry(home.loadpoints.points, answeredAtMs: rig.scheduler.nowMs, level: { _ in nil }, cars: home.cars)
            #expect(entry.asking == [CarEntry.Asking(loadpointID: "garage", session: lp.chargerCar?.session ?? "", choices: [.init(id: DemoCars.modelY, name: "Model Y"), .init(id: DemoCars.zoe, name: "Zoe")])])

            let tap = Task { await home.cars.choose(lp, carID: DemoCars.zoe) }
            await rig.run(100)
            #expect(home.cars.choice["garage"] == CarsModel.Choice(carID: DemoCars.zoe))
            #expect(home.cars.choiceText(try #require(home.cars.choice["garage"])).text == "Sending your choice…")
            await rig.run(200)
            #expect(home.cars.choice["garage"]?.acked == true)
            await rig.run(2_000)
            await tap.value
            #expect(box.receivedCommands.last == Contract.opSessionCarSet)
            let c = try #require(home.cars.choice["garage"])
            #expect(c.result == .applied)
            #expect(home.cars.choiceText(c).text == "FTW now plans for Zoe.")
            #expect(home.cars.choiceReceipt(c).confirmed)
            let named = try #require(home.loadpoints.points.first)
            #expect(named.chargerCar?.carID == DemoCars.zoe)
            #expect(named.chargerCar?.by == .tap)
            #expect(home.cars.asking.isEmpty)
            #expect(home.cars.car(on: named)?.shownName == "Zoe")
            #expect(home.loadpoints.level(named)?.pct == 20)
        }
    }

    @Test func noneOfTheseMakesAVisitorAndAnEndedPlugInIsRefused() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig(.asking)
            let (home, box) = try rig.start()
            await rig.run(2_000)
            let lp = try #require(home.cars.asking.first)
            // The car leaves before the tap lands: the box refuses it.
            box.setCarPluggedIn(false)
            box.setCarPluggedIn(true)
            await rig.settle { await home.cars.choose(lp, carID: DemoCars.modelY) }
            #expect(home.cars.choice["garage"]?.result == .refused("That plug-in has ended."))

            await rig.run(2_000)
            let again = try #require(home.cars.asking.first)
            let tap = Task { await home.cars.choose(again, carID: nil) }
            await rig.run(2_000)
            await tap.value
            let c = try #require(home.cars.choice["garage"])
            #expect(c.result == .applied)
            #expect(home.cars.choiceText(c).text == "FTW now charges it as a visitor's car.")
            #expect(home.loadpoints.points.first?.chargerCar?.by == CarIdentifiedBy.none)
        }
    }

    @Test func theGoalAndTheLevelAreTheCarsOwn() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig(.two)
            let (home, box) = try rig.start()
            await rig.run(2_000)
            let tesla = try #require(home.cars.car(DemoCars.modelY))
            let zoe = try #require(home.cars.car(DemoCars.zoe))

            // A goal for the car that is away: kept on the car.
            await rig.settle { await home.cars.saveGoal(zoe, socPct: 60, clock: 6 * 60 + 30, recurring: true, days: 0b0011111) }
            #expect(box.receivedCommands.last == Contract.opCarGoalSet)
            #expect(home.cars.goalSave[zoe.id] == .saved)
            #expect(home.cars.car(zoe.id)?.goal == Car.Goal(targetPermille: 600, readyByMin: 390, days: 0b0011111, finishAtLimit: false))
            #expect(box.cars?.first(where: { $0.id == zoe.id })?.goal?.readyByMin == 390)

            // A goal for the car on the charger plans that charger.
            await rig.settle { await home.cars.saveGoal(tesla, socPct: 90, clock: 7 * 60, recurring: false, days: 0) }
            #expect(home.cars.car(tesla.id)?.goal == Car.Goal(targetPermille: 900, readyByMin: 420, days: 0, finishAtLimit: false))
            #expect(box.house.schedule?.socFraction == 0.9)
            #expect(box.house.schedule?.recurring == false)

            await rig.settle { await home.cars.removeGoal(zoe) }
            #expect(home.cars.goalSave[zoe.id] == .removed)
            #expect(home.cars.car(zoe.id)?.goal == nil)

            // The level, as the car's own: set by hand, now.
            let level = Task { await home.cars.setLevel(zoe, pct: 55) }
            await rig.run(100)
            #expect(home.cars.levelStep[zoe.id] == EVText.Step(ask: .level(55)))
            #expect(home.cars.chosenLevel(zoe) == 55)
            await rig.run(2_000)
            await level.value
            #expect(box.receivedCommands.last == Contract.opCarSocSet)
            #expect(home.cars.levelStep[zoe.id]?.result == .applied(observed: 0.55))
            let after = try #require(home.cars.car(zoe.id).flatMap { home.cars.level($0) })
            #expect(after.pct == 55)
            #expect(after.source == .manual)
            #expect(CarText.origin(after, nowMs: rig.scheduler.nowMs, zone: CarTextTests.stockholm) == "set by hand · just now")
        }
    }

    @Test func theOwnerKeepsTheListAddRenameCapacitySourcesRemove() async throws {
        let rig = Rig(.one)
        let (home, box) = try rig.start()
        await rig.run(2_000)
        #expect(home.cars.canEdit)
        let tesla = try #require(home.cars.car(DemoCars.modelY))

        await rig.settle { await home.cars.update(tesla, name: "  Teslan ", capacityWh: 75_000) }
        #expect(home.cars.edit[tesla.id] == .saved)
        #expect(home.cars.car(tesla.id)?.name == "Teslan")
        #expect(home.cars.car(tesla.id)?.capacityWh == 75_000)

        // The sources this box could bind: the car's, then the box's others.
        #expect(home.cars.sourceChoices(for: tesla).first == "tesla-ha")
        await rig.settle { await home.cars.update(tesla, sources: []) }
        #expect(home.cars.car(tesla.id)?.sources == [])

        await rig.settle { await home.cars.add(name: "Zoe", capacityWh: 52_000) }
        #expect(home.cars.edit[CarsModel.newCarKey] == .saved)
        let zoe = try #require(home.cars.cars.first { $0.name == "Zoe" })
        #expect(Car.isID(zoe.id))
        #expect(zoe.capacityWh == 52_000)

        await rig.settle { await home.cars.remove(zoe) }
        #expect(home.cars.edit[zoe.id] == .removed)
        #expect(home.cars.car(zoe.id) == nil)
        #expect(box.removed == [zoe.id])
        #expect(box.receivedCommands.suffix(1) == [Contract.opCarRemove])
    }

    /// An old box refuses the car ops it does not know, and the words say
    /// what happens now.
    @Test func aRefusedCarOpSaysWhatHappensNow() {
        AppWords.$language.withValue(.en) {
            let r = CmdResult(cmdId: "c", state: .rejected, errorCode: "E_PRECONDITION", errorArgs: ["reason": .text("elsewhere")])
            #expect(CarText.refusal(r) == "That car is on another charger.")
            #expect(CarText.refusal(CmdResult(cmdId: "c", state: .rejected, errorCode: "E_DUPLICATE")) == "Another car already has that VIN or tag.")
            #expect(CarText.refusal(CmdResult(cmdId: "c", state: .rejected, errorCode: "E_NOT_FOUND", errorArgs: ["reason": .text("car")])) == "FTW no longer has this car.")
        }
    }
}
