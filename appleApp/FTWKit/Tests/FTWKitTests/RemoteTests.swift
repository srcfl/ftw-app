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

            // Started once, at the box's confirmation; the read after it
            // found the hold and moved nothing back.
            guard case .start(let s)? = rig.activities.log.first else {
                Issue.record("no Live Activity: \(rig.activities.log)")
                return
            }
            #expect(s.startedAtMs == s.confirmedAtMs)
            #expect(s.startedAtMs > CarTextTests.t)
            #expect(rig.activities.log.dropFirst().allSatisfy { if case .update = $0 { return true } else { return false } })
            #expect(rig.activities.states["demo/garage"]?.startedAtMs == s.startedAtMs)
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

            let out = await rig.perform(.backToPlan(loadpointID: "garage"), loadpoints, for: 3_000)
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

    /// Received and never confirmed, and the charger does not hold it: no
    /// Live Activity, and the answer says the box has not confirmed.
    @Test func anUnconfirmedChargeNowStartsNothing() async throws {
        try await AppWords.$language.withValue(.en) {
            let rig = Rig()
            let loadpoints = try rig.start()
            rig.box?.neverConfirm = true
            let out = await rig.perform(.chargeNow, loadpoints, for: 22_000)
            #expect(out.kind == .pending)
            #expect(out.text == "FTW received it but has not confirmed the result yet.")
            #expect(rig.activities.log.isEmpty)
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

            let locked = loadpoints.answer(locked: true)
            #expect(locked.gist == open.gist)
            #expect(locked.details.isEmpty)
            #expect(!locked.headline.contains("%"))
            #expect(!locked.headline.contains(":"))

            _ = await rig.perform(.chargeNow, loadpoints)
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

/// The Live Activity, as a list of what the model asked for.
@MainActor
final class FakeActivities: ChargeNowHost {
    var states: [String: ChargeNowActivity.State] = [:]
    var log: [ChargeNowActivity.Action] = []

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

    func send(_ frame: Bytes) {
        if let d = try? Frame.decode(frame), d.envelope.t == "cmd", let b = d.envelope.b {
            commands.append(Command(op: b["op"]?.string ?? "", args: b["args"] ?? CBOR.emptyMap, notValidAfterMs: b["notValidAfterMs"]?.double, uptimeMs: uptimeMs))
        }
        inner.send(frame)
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
