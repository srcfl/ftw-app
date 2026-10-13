import Foundation
import Testing
@testable import FTWKit
import FTWDemo
import FTWShared

/// Commands from outside the app (Control, Siri, the Live Activity) against
/// the simulated box: what goes on the wire, how each ends, and how the
/// Live Activity follows the box's `cmd.result`. In English unless a test
/// says otherwise.
@MainActor
@Suite struct RemoteTests {
    @MainActor
    final class Rig {
        let scheduler: ManualScheduler
        var box: SimulatedBox?
        var wire: RecordingCarrier?
        var app: AppModel!
        let activities = FakeActivities()

        init(nowMs: Double = CarTextTests.t) {
            scheduler = ManualScheduler(nowMs: nowMs)
            app = AppModel(store: MemoryStore(), files: nil, passkeys: nil, scheduler: scheduler, build: "test", ua: "test", demo: { [unowned self] s in
                let box = SimulatedBox(scheduler: s, house: SimulatedHouse(timeZone: CarTextTests.stockholm))
                box.resultDelayMs = 900
                box.house.chargerRampMs = 4_000
                self.box = box
                let wire = RecordingCarrier(inner: LoopbackCarrier(box: box, scheduler: s))
                self.wire = wire
                return wire
            })
        }

        /// The demo home, with the fake Live Activity in place.
        func start() throws -> LoadpointsModel {
            app.startDemo()
            let loadpoints = try #require(app.home?.loadpoints)
            loadpoints.chargeNowHost = activities
            return loadpoints
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

        /// Run a command the way an intent does, from a cold app: nothing
        /// read yet, the stream not yet up.
        func perform(_ command: RemoteCommand, _ loadpoints: LoadpointsModel, loadpointID: String? = nil, for ms: Double = 5_000) async -> RemoteOutcome {
            let task = Task { await loadpoints.perform(command, loadpointID: loadpointID) }
            await run(ms)
            return await task.value
        }
    }

    // MARK: The intent's body on the wire

    /// Charge now from a Control: the charger's full current, held with no
    /// time limit, valid for two minutes of box uptime. The box's result
    /// starts the Live Activity at the moment it confirmed.
    @Test func chargeNowFromOutsideSendsTheHoldAndStartsTheLiveActivity() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            let out = await rig.perform(.chargeNow, loadpoints)
            #expect(out.kind == .done)
            #expect(out.text == "FTW started charging. Waiting for the car to draw power.")

            let wire = try #require(rig.wire)
            let cmd = try #require(wire.commands.last)
            #expect(cmd.op == Contract.opLoadpointHold)
            #expect(cmd.args["id"]?.string == "garage")
            #expect(cmd.args["power_w"]?.double == 11_000)
            #expect(cmd.args["hold_s"]?.double == 0)
            #expect(cmd.args["phase_mode"]?.string == "3p")
            #expect(cmd.args["clear"] == nil)
            let valid = try #require(cmd.notValidAfterMs)
            #expect(abs(valid - (cmd.uptimeMs + Session.cmdValidForMs)) < 1)
            #expect(cmd.uptimeMs > 0)
            #expect(rig.box?.house.manualHoldW == 11_000)

            // Started when sent, then received, then on from the box's
            // confirmation; the read after it found the hold.
            guard case .start(let sent)? = rig.activities.log.first else {
                Issue.record("no Live Activity: \(rig.activities.log)")
                return
            }
            #expect(sent.phase == .sent)
            let phases = rig.activities.log.compactMap { action -> ChargeNowActivity.State.Phase? in
                if case .update(let s) = action { return s.phase }
                return nil
            }
            #expect(phases.first == .received)
            #expect(phases.contains(.on))
            #expect(rig.activities.log.dropFirst().allSatisfy { if case .update = $0 { return true } else { return false } })
            let on = try #require(rig.activities.states["demo/garage"])
            #expect(on.phase == .on)
            #expect(on.startedAtMs > sent.startedAtMs)
        }
    }

    /// Back to the plan from the Live Activity's button: a clear, and the
    /// Live Activity ends on the box's result.
    @Test func backToThePlanClearsTheHoldAndEndsTheLiveActivity() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            _ = await rig.perform(.chargeNow, loadpoints)
            #expect(rig.activities.states["demo/garage"] != nil)

            let out = await rig.perform(.backToPlan(loadpointID: "garage", home: "demo"), loadpoints, for: 3_000)
            #expect(out.kind == .done)
            #expect(out.text == "Back to the plan. FTW decides when to charge.")
            let cmd = try #require(rig.wire?.commands.last)
            #expect(cmd.op == Contract.opLoadpointHold)
            #expect(cmd.args["clear"]?.bool == true)
            #expect(cmd.args["id"]?.string == "garage")
            #expect(rig.box?.house.manualHoldW == nil)
            #expect(rig.activities.log.last == .end)
            #expect(rig.activities.states["demo/garage"] == nil)
        }
    }

    /// A read that no longer finds the hold ends the Live Activity: someone
    /// went back to the plan elsewhere.
    @Test func aReadWithoutTheHoldEndsTheLiveActivity() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            _ = await rig.perform(.chargeNow, loadpoints)
            #expect(rig.activities.states["demo/garage"] != nil)
            rig.box?.house.manualHoldW = nil
            let read = Task { try? await loadpoints.loadChargers() }
            await rig.run(1_000)
            await read.value
            #expect(rig.activities.log.last == .end)
        }
    }

    /// Charge now in the car view moves the same Live Activity.
    @Test func chargeNowInTheAppStartsItToo() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(loadpoints.points.first)
            let tap = Task { await loadpoints.chargeNow(car) }
            await rig.run(3_000)
            await tap.value
            guard case .start? = rig.activities.log.first else {
                Issue.record("no Live Activity: \(rig.activities.log)")
                return
            }
            let pause = Task { await loadpoints.pause(car) }
            await rig.run(3_000)
            await pause.value
            #expect(rig.activities.log.last == .end)
        }
    }

    /// Received and never confirmed, and the charger does not hold it: the
    /// card that showed it on its way closes, never having said "on", and
    /// the answer says the box has not confirmed.
    @Test func anUnconfirmedChargeNowLeavesNoCard() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.box?.neverConfirm = true
            let out = await rig.perform(.chargeNow, loadpoints, for: 22_000)
            #expect(out.kind == .pending)
            #expect(out.text == "FTW received it but has not confirmed the result yet.")
            #expect(rig.activities.log.last == .end)
            #expect(rig.activities.states.isEmpty)
            #expect(!rig.activities.log.contains { action in
                if case .update(let s) = action { return s.phase == .on }
                if case .start(let s) = action { return s.phase == .on }
                return false
            })
        }
    }

    /// The level from Siri: `loadpoint.soc.set` as a fraction.
    @Test func theLevelFromSiriIsAFraction() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            let out = await rig.perform(.setLevel(pct: 40), loadpoints)
            #expect(out.kind == .done)
            #expect(out.text == "FTW now plans from 40\u{00A0}%.")
            let cmd = try #require(rig.wire?.commands.last)
            #expect(cmd.op == Contract.opLoadpointSocSet)
            #expect(cmd.args["soc"]?.double == 0.4)
            #expect(cmd.args["id"]?.string == "garage")
            #expect(rig.activities.log.isEmpty)
        }
    }

    /// A notification's 50 %: any whole level, on the charger its event
    /// named. A charger the box does not have is never swapped for one it
    /// does.
    @Test func aNotificationNamesItsCharger() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            let out = await rig.perform(.setLevel(pct: 50), loadpoints, loadpointID: "garage")
            #expect(out.kind == .done)
            let cmd = try #require(rig.wire?.commands.last)
            #expect(cmd.op == Contract.opLoadpointSocSet)
            #expect(cmd.args["soc"]?.double == 0.5)
            #expect(cmd.args["id"]?.string == "garage")

            let sent = rig.wire?.commands.count
            let elsewhere = await rig.perform(.chargeNow, loadpoints, loadpointID: "street")
            #expect(elsewhere.kind == .failed)
            #expect(elsewhere.text == "FTW has no charger to control.")
            #expect(rig.wire?.commands.count == sent)
        }
    }

    /// The box refuses a level for a car that is not plugged in; Siri says
    /// what to do.
    @Test func aRefusalIsAFailureThatSaysWhatToDo() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.box?.setCarPluggedIn(false)
            let out = await rig.perform(.setLevel(pct: 40), loadpoints)
            #expect(out.kind == .failed)
            #expect(out.text == "Plug the car in first. FTW takes a level only while the car is plugged in.")
        }
    }

    /// No stream in time: nothing is sent and the answer says so.
    @Test func noStreamSendsNothing() async {
        await AppWords.$language.withValue(.en) {
            let scheduler = ManualScheduler(nowMs: CarTextTests.t)
            let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: nil)
            let loadpoints = LoadpointsModel(site: site, charging: nil, cache: nil)
            let task = Task { await loadpoints.perform(.chargeNow, waitMs: 2_000) }
            for _ in 0..<50 {
                for _ in 0..<5 { await Task.yield() }
                scheduler.advance(100)
            }
            let out = await task.value
            #expect(out.kind == .failed)
            #expect(out.text == "Not connected to FTW right now. Try again when the connection is back.")
        }
    }

    // MARK: Never another home's

    /// The demo's card, or another home's, closes when its button is
    /// pressed, and nothing reaches this home's charger.
    @Test func aButtonFromAnotherHomeSendsNothingAndClosesItsCard() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.activities.states["somewhere-else/garage"] = ChargeNowActivity.State(startedAtMs: CarTextTests.t, confirmedAtMs: CarTextTests.t)
            let out = await rig.perform(.backToPlan(loadpointID: "garage", home: "somewhere-else"), loadpoints, for: 3_000)
            #expect(out.kind == .failed)
            #expect(out.text == "That card was for another home. It is closed now.")
            #expect(rig.wire?.commands.isEmpty == true)
            #expect(rig.activities.states["somewhere-else/garage"] == nil)
            #expect(rig.box?.house.manualHoldW == nil)
        }
    }

    /// Exit demo and Remove this phone end every Live Activity; a home that
    /// opens ends every other home's.
    @Test func leavingAHomeEndsItsLiveActivities() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            _ = await rig.perform(.chargeNow, loadpoints)
            #expect(rig.activities.states["demo/garage"] != nil)
            loadpoints.endLiveActivities()
            #expect(rig.activities.endedAllExcept.last == .some(nil))
            #expect(rig.activities.states.isEmpty)

            let other = FakeActivities()
            other.states["demo/garage"] = ChargeNowActivity.State(startedAtMs: CarTextTests.t, confirmedAtMs: CarTextTests.t)
            let scheduler = ManualScheduler(nowMs: CarTextTests.t)
            let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: scheduler, files: nil)
            _ = LoadpointsModel(site: site, charging: nil, cache: nil, chargeNowHost: other)
            #expect(other.endedAllExcept == ["home"])
            #expect(other.states.isEmpty)
        }
    }

    /// Exit demo and Remove this phone leave no Live Activity behind.
    @Test func exitDemoAndLeaveEndEveryLiveActivity() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            _ = await rig.perform(.chargeNow, loadpoints)
            #expect(rig.activities.states["demo/garage"] != nil)
            rig.app.exitDemo()
            #expect(rig.activities.states.isEmpty)
            #expect(rig.activities.endedAllExcept.contains { $0 == nil })

            let again = Rig()
            let second = try again.start()
            _ = await again.perform(.chargeNow, second)
            #expect(again.activities.states["demo/garage"] != nil)
            again.app.leave()
            #expect(again.activities.states.isEmpty)
        }
    }

    /// With a Live Activity up, the stream coming back while someone looks
    /// reads the chargers once by itself, and a charger the box no longer
    /// lists ends its Live Activity.
    @Test func aChargerThatIsGoneEndsItsLiveActivity() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.activities.states["demo/old"] = ChargeNowActivity.State(startedAtMs: CarTextTests.t, confirmedAtMs: CarTextTests.t)
            #expect(loadpoints.readAtMs == nil)
            await rig.run(3_000)
            #expect(loadpoints.readAtMs != nil)
            #expect(rig.activities.states["demo/old"] == nil)
            #expect(rig.activities.log.contains(.end))
        }
    }

    // MARK: The Control

    /// The App Group's car record carries Charge now as the box confirmed
    /// it, which is all the Control reads.
    @Test func theCarRecordCarriesTheHold() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ftw-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = AppGroupFiles(directory: dir)
        let site = SiteModel(siteId: "home", build: "test", ua: "test", scheduler: ManualScheduler(nowMs: CarTextTests.t), files: nil, shared: shared)
        let holding = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":11000}"#.utf8)))
        site.shareCars([holding], fresh: true)
        await site.flushShared()
        #expect(shared.read(CarEntry.self, siteId: "home")?.value.cars.first?.holding == true)
        let paused = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":0}"#.utf8)))
        site.shareCars([paused], fresh: true)
        await site.flushShared()
        #expect(shared.read(CarEntry.self, siteId: "home")?.value.cars.first?.holding == false)
    }

    /// Charge now with no car refuses, sends nothing, and says why.
    @Test func chargeNowWithNoCarRefuses() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.box?.setCarPluggedIn(false)
            let out = await rig.perform(.chargeNow, loadpoints)
            #expect(out.kind == .failed)
            #expect(out.text == "The car is not plugged in.")
            #expect(rig.wire?.commands.isEmpty == true)
            #expect(rig.activities.log.isEmpty)
        }
    }

    /// The Control hears when the box's account of Charge now changes, and
    /// only then.
    @Test func theControlIsToldWhenTheHoldChanges() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            loadpoints.activate()
            await rig.run(1_500)
            let first = rig.activities.controlReloads
            #expect(first >= 1)
            loadpoints.reread()
            await rig.run(1_000)
            #expect(rig.activities.controlReloads == first)
            _ = await rig.perform(.chargeNow, loadpoints)
            #expect(rig.activities.controlReloads == first + 1)
        }
    }

    /// A Control's refused command opens the app, and the reason waits on
    /// the car's receipt.
    @Test func aRefusalWaitsOnTheReceipt() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            loadpoints.activate()
            await rig.run(1_500)
            let car = try #require(loadpoints.primary)
            loadpoints.show(refusal: "The car is not plugged in.")
            #expect(loadpoints.outcome(hold: car)?.text == "The car is not plugged in.")
            #expect(loadpoints.outcome(hold: car)?.tone == .failed)
        }
    }

    /// A command while another is unfinished says FTW is busy; it never
    /// reports the other command's outcome as its own.
    @Test func aCommandDuringAnUnfinishedOneIsBusy() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.box?.neverConfirm = true
            let first = Task { await loadpoints.perform(.chargeNow) }
            await rig.run(3_000)
            let second = await rig.perform(.backToPlan(loadpointID: nil, home: nil), loadpoints, for: 2_000)
            #expect(second.kind == .failed)
            #expect(second.text == "FTW is still busy with your last command. Try again in a moment.")
            #expect(rig.wire?.commands.count == 1)
            await rig.run(20_000, step: 500)
            _ = await first.value
        }
    }

    // MARK: Is the car ready?

    /// Unlocked, the car view's sentences; locked, the gist alone, with no
    /// level, time or power.
    @Test func isTheCarReadyHidesTheDetailsWhenLocked() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            let read = Task { await loadpoints.refreshForAnswer() }
            await rig.run(3_000)
            #expect(await read.value)

            let open = loadpoints.answer(locked: false)
            #expect(open.gist == .pluggedIn || open.gist == .onTrack || open.gist == .short || open.gist == .ready)
            #expect(open.details.first?.hasPrefix("20\u{00A0}%") == true)
            #expect(open.canChargeNow)
            #expect(!open.holding)
            #expect(open.home == "demo")

            let locked = loadpoints.answer(locked: true)
            #expect(locked.gist == open.gist)
            #expect(locked.details.isEmpty)
            #expect(!locked.headline.contains("%"))
            #expect(!locked.headline.contains(":"))

            _ = await rig.perform(.chargeNow, loadpoints)
            // The card shows the box's outcome in place; locked, it does not.
            #expect(loadpoints.answer(locked: false).receipt == "FTW started charging. Waiting for the car to draw power.")
            #expect(loadpoints.answer(locked: true).receipt == nil)
            let charging = loadpoints.answer(locked: true)
            #expect(charging.gist == .chargingNow)
            #expect(charging.headline == "Charge now is on.")
            #expect(charging.holding)
            #expect(!charging.canChargeNow)
            #expect(loadpoints.answer(locked: false).headline != charging.headline)

            rig.box?.setCarPluggedIn(false)
            let unplug = Task { try? await loadpoints.loadChargers() }
            await rig.run(1_000)
            await unplug.value
            #expect(loadpoints.answer(locked: true).headline == "The car is not plugged in.")
        }
    }

    @Test func theGistInSwedish() {
        AppWords.$language.withValue(.sv) {
            for (gist, en) in CarAnswer.gistWords {
                let sv = LoadpointsModel.say(en)
                #expect(sv != en, "no Swedish for \(gist)")
            }
            #expect(LoadpointsModel.say("The car is ready.") == "Bilen är klar.")
        }
    }
}

// MARK: - Test doubles

/// The Live Activity and the Control, as a list of what the model asked
/// for.
@MainActor
final class FakeActivities: ChargeNowHost {
    var states: [String: ChargeNowActivity.State] = [:]
    var log: [ChargeNowActivity.Action] = []
    var endedAllExcept: [String?] = []
    var controlReloads = 0

    func current(home: String, loadpointID: String) -> ChargeNowActivity.State? {
        states["\(home)/\(loadpointID)"]
    }

    func apply(_ action: ChargeNowActivity.Action, home: String, loadpointID: String, zone: TimeZone) {
        log.append(action)
        switch action {
        case .start(let s), .update(let s): states["\(home)/\(loadpointID)"] = s
        case .end: states["\(home)/\(loadpointID)"] = nil
        case .none: break
        }
    }

    func loadpointIDs(home: String) -> [String] {
        states.keys.filter { $0.hasPrefix("\(home)/") }.map { String($0.dropFirst(home.count + 1)) }
    }

    func endAll(except home: String?) {
        endedAllExcept.append(home)
        states = states.filter { key, _ in home.map { key.hasPrefix("\($0)/") } ?? false }
    }

    func holdChanged() {
        controlReloads += 1
    }
}

/// A carrier that passes everything through and keeps every `cmd` the app
/// sends, decoded, with the session's uptime when it went.
@MainActor
final class RecordingCarrier: Carrier {
    struct Command {
        var op: String
        var args: CBOR
        var notValidAfterMs: Double?
        var uptimeMs: Double
    }

    let inner: Carrier
    private(set) var commands: [Command] = []
    /// Box uptime as the frames say, for the command's validity window.
    private var uptimeMs: Double = 0

    init(inner: Carrier) {
        self.inner = inner
    }

    var kind: CarrierKind { inner.kind }
    var status: CarrierStatus { inner.status }

    @discardableResult
    func send(_ frame: Bytes) -> Bool {
        if let d = try? Frame.decode(frame), d.envelope.t == "cmd", let b = d.envelope.b {
            commands.append(Command(op: b["op"]?.string ?? "", args: b["args"] ?? CBOR.emptyMap, notValidAfterMs: b["notValidAfterMs"]?.double, uptimeMs: uptimeMs))
        }
        return inner.send(frame)
    }

    func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        inner.setHandlers(onFrame: { [weak self] bytes in
            if let d = try? Frame.decode(bytes), let up = d.envelope.b?["uptimeMs"]?.double { self?.uptimeMs = up }
            onFrame(bytes)
        }, onStatus: onStatus)
    }

    func wake() { inner.wake() }
    func close(reason: String) { inner.close(reason: reason) }
}
