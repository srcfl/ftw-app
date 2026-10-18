import Foundation
import Testing
@testable import FTWKit

/// The sentences and figures the web app's own tests pin, so both apps say
/// the same thing about the same house.
@Suite struct FormatTests {
    typealias F = Contract.FID

    @Test func explanationsMatchTheWebApp() {
        func explain(_ f: [Int: Double], blocked: [String] = [], ceiling: Double? = nil) -> Explanation.Result {
            Explanation.explain(fields: f, dispatchBlockedBy: blocked, ceilingW: ceiling)
        }
        let shaving = explain([F.gridW: 11_000, F.pvW: 0, F.batteryW: -4200, F.loadW: 15_200], ceiling: 11_000)
        #expect(shaving.situation == .batteryShaving)
        #expect(shaving.headline == "The battery is supplying 4.2 kW to keep grid import below 11 kW.")
        let covering = explain([F.gridW: 0, F.pvW: 0, F.batteryW: -2100, F.loadW: 2100])
        #expect(covering.headline == "The battery is covering the house, so nothing is coming from the grid.")
        let importing = explain([F.gridW: 2400, F.pvW: 0, F.batteryW: 0, F.loadW: 2400])
        #expect(importing.headline == "The house is drawing 2.4 kW from the grid.")
        #expect(explain([F.gridW: -3000, F.pvW: -5000, F.batteryW: 0, F.loadW: 2000]).situation == .exportingSurplus)
        #expect(explain([F.gridW: 0, F.pvW: -5000, F.batteryW: 3000, F.loadW: 2000]).situation == .chargingFromSurplus)
        #expect(explain([F.gridW: 10, F.pvW: -2000, F.batteryW: 0, F.loadW: 2000]).situation == .solarCovering)
        #expect(explain([F.gridW: 800, F.pvW: -1200, F.batteryW: 0, F.loadW: 2000]).situation == .solarPartial)
        #expect(explain([F.gridW: 2400, F.loadW: 2400], blocked: ["meter"]).situation == .dispatchBlocked)
        #expect(explain([:]).situation == .noData)
        #expect(!explain([F.gridW: -3000, F.pvW: -5000, F.batteryW: -100, F.loadW: 2000]).headline.contains("-"))
    }

    @Test func evSentencesSayOnlyWhatTheBoxSaid() throws {
        try AppWords.$language.withValue(.en) {
            let unplugged = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":false,"current_soc":0.5}"#.utf8)))
            #expect(EVText.status(unplugged) == "Not plugged in")
            #expect(unplugged.socPct == nil)

            let charging = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"current_power_w":7200,"current_soc":0.41,"delivered_wh_session":3040}"#.utf8)))
            #expect(EVText.status(charging) == "Charging at 7.2\u{00A0}kW")
            #expect(charging.socPct == 41)
            #expect(EVText.session(charging) == "3.0\u{00A0}kWh this session")

            let paused = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"manual_active":true,"manual_charge_w":0,"manual":{"state":"paused"}}"#.utf8)))
            #expect(EVText.isPaused(paused))
            #expect(EVText.status(paused) == "Paused by you")

            let stale = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"charger":{"known":true,"available":false}}"#.utf8)))
            #expect(EVText.status(stale) == "Charger status is out of date.")

            #expect(EVText.days(0) == "every day")
            #expect(EVText.days(0b0011111) == "weekdays")
            #expect(EVText.days(0b1100000) == "weekends")
            #expect(EVText.days(0b0000101) == "Mon, Wed")
        }
    }

    /// A level from the car is as old as the car's report. Any other level
    /// is the box's account as of its answer.
    @Test func theCarsLevelCarriesWhenItWasRead() throws {
        let fromCar = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"current_soc":0.6,"soc_source":"vehicle","vehicle_soc_age_s":120}"#.utf8)))
        #expect(fromCar.socReadAtMs(answeredAtMs: 1_000_000) == 880_000)
        let assumed = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"current_soc":0.2,"soc_source":"assumed"}"#.utf8)))
        #expect(assumed.socReadAtMs(answeredAtMs: 1_000_000) == 1_000_000)
        let unplugged = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":false,"current_soc":0.6}"#.utf8)))
        #expect(unplugged.socReadAtMs(answeredAtMs: 1_000_000) == nil)
    }

    @Test func chargeCurrentFallsBackLikeTheBoxPage() throws {
        let bare = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true}"#.utf8)))
        #expect(EVText.current(bare) == EVText.Current(minA: 6, maxA: 16, wattsPerAmp: 690, phases: 3))
        let capped = Loadpoint(try JSON(parsing: Array(#"{"id":"a","plugged_in":true,"max_charge_w":11000,"min_charge_w":4140}"#.utf8)))
        // 16 A is 11 040 W, above the charger's ceiling: the ceiling wins.
        #expect(EVText.watts(capped, amps: 16) == 11_000)
        #expect(EVText.readout(capped, amps: 16) == "16 A · 11.0 kW")
    }

    @Test func flowUsesMagnitudesAndDirections() {
        let r = Flow.readings(fields: [F.gridW: -1500, F.pvW: -4000, F.batteryW: 1200, F.batterySoc: 612, F.loadW: 1300])
        let grid = r.nodes.first { $0.role == .grid }!
        #expect(grid.kw == 1.5)
        #expect(!grid.toHub)
        #expect(grid.sub == "exporting")
        let battery = r.nodes.first { $0.role == .battery }!
        #expect(battery.sub == "charging")
        #expect(battery.socPct == 61)
        #expect(!r.nodes.contains { $0.role == .ev })
        let overlaid = Flow.withLoadpointEV([F.loadW: 9000, F.evW: 0], evW: 7400)
        #expect(overlaid[F.evW] == 7400)
        #expect(overlaid[F.loadW] == 9000)
    }

}

/// The beams on Now: what width, speed and light a reading gives, and how a
/// beam moves between frames. Light means live: a cache never glows.
@Suite struct FlowBeamTests {
    func target(_ kw: Double, live: Bool, node: EnergyNode = .battery) -> Flow.BeamTarget {
        Flow.BeamTarget(node: node, kw: kw, live: live, flowing: kw * 1000 > Flow.idleW, towardHome: true)
    }

    /// Steps a beam at 120 Hz from `from` to `to` seconds, giving each frame.
    func run(_ m: inout Flow.BeamMotion, _ t: Flow.BeamTarget, from: Double, to: Double, reduceMotion: Bool = false) -> [Flow.BeamFrame] {
        var out = [Flow.BeamFrame]()
        var s = from
        while s <= to + 1e-9 {
            out.append(m.step(t, at: s, reduceMotion: reduceMotion))
            s += 1.0 / 120
        }
        return out
    }

    @Test func figuresStepAsTheirDigitsDo() {
        #expect(Flow.quantised(3) == 0)
        #expect(Flow.quantised(994) == 990)
        #expect(Flow.quantised(996) == 1_000)
        #expect(Flow.quantised(2_349) == 2_300)
        #expect(Flow.quantised(2_351) == 2_400)
        #expect(Flow.quantised(9_949) == 9_900)
        #expect(Flow.quantised(9_951) == 10_000)
        #expect(Flow.quantised(12_340) == 12_000)
        #expect(Flow.quantised(-634) == -630)
        #expect(Flow.quantised(.nan) == 0)
        // The value changes exactly when the digits on screen do, so a
        // figure rolls only when it says something new.
        var w = 0.0
        while w < 20_000 {
            let a = Flow.quantised(w), b = Flow.quantised(w + 3)
            #expect((a == b) == (PowerFormat.parts(a).text == PowerFormat.parts(b).text), "\(w)")
            w += 3
        }
    }

    /// A figure on a rounding edge holds still: the one shown changes only
    /// when the reading moves more than 60 % of a step away from it.
    @Test func aFigureHoldsStillOnARoundingEdge() {
        // 1.45 kW read as 1,449, 1,451 and 1,446 W: 1.4 or 1.5, but not both.
        var shown: Double?
        var seen = Set<Double>()
        for w in [1_449.0, 1_451, 1_446, 1_452, 1_448, 1_455, 1_445] {
            shown = Flow.quantised(w, holding: shown)
            seen.insert(shown!)
        }
        #expect(seen == [1_400])
        // Past 60 % of a step it moves, to where the reading rounds.
        #expect(Flow.quantised(1_461, holding: 1_400) == 1_500)
        #expect(Flow.quantised(1_460, holding: 1_400) == 1_400)
        #expect(Flow.quantised(1_339, holding: 1_400) == 1_300)
        // Nothing shown yet, or nothing finite: as without a hold.
        #expect(Flow.quantised(1_449, holding: nil) == 1_400)
        #expect(Flow.quantised(1_449, holding: .nan) == 1_400)
        // Across a step size the larger step counts.
        #expect(Flow.quantised(1_040, holding: 990) == 990)
        #expect(Flow.quantised(1_060, holding: 990) == 1_100)
        // Idle stays idle under a few watts of noise.
        #expect(Flow.quantised(5, holding: 0) == 0)
        #expect(Flow.quantised(7, holding: 0) == 10)
    }

    @Test func widthAndSpeedFollowThePower() {
        #expect(Flow.beamWidth(kw: 0) == 1.25)
        #expect(abs(Flow.beamWidth(kw: 1) - 2.35) < 1e-9)
        #expect(Flow.beamWidth(kw: -1) == Flow.beamWidth(kw: 1))
        #expect(Flow.beamWidth(kw: 10) == 6)
        #expect(abs(Flow.waveSpeed(kw: 0.1) - 19.2) < 0.1)
        #expect(abs(Flow.waveSpeed(kw: 1) - 31.4) < 0.1)
        #expect(abs(Flow.waveSpeed(kw: 10) - 51.5) < 0.1)
    }

    @Test func theWaveIsSoftCrestsAWavelengthApart() {
        let lam = Flow.wavelength
        #expect(abs(Flow.wave(0.3 * lam, phase: 0.3) - 1) < 1e-9)
        #expect(abs(Flow.wave(0.8 * lam, phase: 0.3) - 0.45) < 1e-9)
        for s in stride(from: 0.0, to: 90, by: 1.7) {
            #expect(abs(Flow.wave(s, phase: 0.1) - Flow.wave(s + lam, phase: 0.1)) < 1e-9)
            #expect((0.45...1).contains(Flow.wave(s, phase: 0.1)))
        }
    }

    @Test func aFollowSwellsWithoutOvershootAndStepsExactly() {
        var f = Flow.Follow(1)
        var peak = 1.0
        for _ in 0..<(120 * 3) {
            f.step(toward: 3, dt: 1.0 / 120, tau: 0.4)
            peak = max(peak, f.value)
        }
        #expect(peak <= 3)
        #expect(abs(f.value - 3) < 0.01)
        // One long frame lands where many short ones would.
        var long = Flow.Follow(1), short = Flow.Follow(1)
        long.step(toward: 3, dt: 0.5, tau: 0.4)
        for _ in 0..<60 { short.step(toward: 3, dt: 0.5 / 60, tau: 0.4) }
        #expect(abs(long.value - short.value) < 1e-9)
    }

    @Test func aCacheNeverGlows() {
        // A beam drawn from the cache, frame after frame, never lights.
        var m = Flow.BeamMotion(target(2.3, live: false), at: 0)
        for f in run(&m, target(2.3, live: false), from: 0, to: 10) {
            #expect(f.light == 0)
            #expect(f.alpha == 0.35)
            #expect(f.depth == 0)
            #expect(f.phase == 0)
        }
        // A reading kept on the phone reads back as the cache, not live.
        let kept = NodeReading(node: .battery, watts: 2_300, word: "", tone: .discharging, towardHome: true, levelPct: 61, levelAssumed: false,
                               freshness: NodeFreshness(carrier: .cache, srcState: .live, ageMs: 4_000, sourceName: nil))
        #expect(!Flow.BeamTarget(kept).live)
        #expect(Flow.Light(live: false, at: 0).level(at: 100) == 0)
    }

    @Test func theFirstLiveFrameIgnitesWithTheSpringAndLiveEndingDecays() {
        var m = Flow.BeamMotion(target(2.3, live: false), at: 0)
        _ = run(&m, target(2.3, live: false), from: 0, to: 1)
        let lit = run(&m, target(2.3, live: true), from: 1, to: 3)
        // Up together: not at once, nearly full after the spring's 0.35 s,
        // a brief flash at most.
        #expect(lit[0].light < 0.05)
        #expect(lit[Int(0.4 * 120)].light > 0.98)
        #expect((lit.map(\.light).max() ?? 0) < 1.08)
        #expect(lit.last!.phase > 0, "the wave never ran")
        // Decay: exponential, τ 0.4 s, and the wave at rest in 0.35 s.
        var light = Flow.Light(live: true, at: 0)
        light.set(live: false, at: 10)
        #expect(abs(light.level(at: 10.4) - exp(-1)) < 1e-9)
        #expect(light.motion(at: 10.35) < 1e-9)
        #expect(light.motion(at: 10.5) == 0)
        let cooled = run(&m, target(2.3, live: false), from: 3, to: 4)
        #expect(abs(cooled[Int(0.4 * 120)].light - exp(-1)) < 0.02)
        let rest = cooled[Int(0.35 * 120) + 1].phase
        #expect(cooled.last!.phase == rest, "the wave kept running after its rest")
    }

    @Test func theLightRunsSourceToSinkAtThePowersSpeed() {
        var m = Flow.BeamMotion(target(1, live: true), at: 0)
        let frames = run(&m, target(1, live: true), from: 0, to: 2)
        let expected = 2 * Flow.waveSpeed(kw: 1) / Flow.wavelength
        #expect(abs(frames.last!.phase - expected) < 0.01)
        // Phase grows: crests at s = λ(φ + j) move away from the source.
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.phase < $1.phase })
    }

    @Test func aNewReadingSwellsTheBeamRatherThanSnapping() {
        var m = Flow.BeamMotion(target(0.5, live: true), at: 0)
        let frames = run(&m, target(3, live: true), from: 0, to: 3)
        #expect(frames[1].width < Flow.beamWidth(kw: 0.5) + 0.05)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.width <= $1.width + 1e-9 })
        #expect(frames.allSatisfy { $0.width <= Flow.beamWidth(kw: 3) + 1e-9 })
        #expect(abs(frames.last!.width - Flow.beamWidth(kw: 3)) < 0.02)
    }

    @Test func aNodeAtRestIsAStillHairlineAndCrossFadesIntoABeam() {
        var m = Flow.BeamMotion(target(0.02, live: true), at: 0)
        #expect(m.step(target(0.02, live: true), at: 0, reduceMotion: false).idle == 1)
        let start = run(&m, target(1.5, live: true), from: 0, to: 1.5)
        #expect(start[1].idle > 0.9)
        #expect(start.last!.idle < 0.01)
    }

    @Test func reduceMotionHoldsTheLightStillAndSnaps() {
        var m = Flow.BeamMotion(target(0.5, live: false), at: 0)
        let frames = run(&m, target(3, live: true), from: 0, to: 1, reduceMotion: true)
        #expect(frames.allSatisfy { $0.phase == 0 })
        #expect(frames[0].width == Flow.beamWidth(kw: 3))
        // Live still shows, at once.
        #expect(frames[0].light == 1)
        let off = run(&m, target(3, live: false), from: 1, to: 1.1, reduceMotion: true)
        #expect(off[0].light == 0)
    }
}

/// Where the flow's parts sit, by the box's own rules, and the beams
/// between them.
@Suite struct FlowPlanTests {
    let all: [EnergyNode] = [.solar, .battery, .home, .grid, .car]

    @Test func eachNodeHasItsCornerAndAMissingPartnerMovesItOntoTheAxis() {
        #expect(all.map { FlowPlan.spot($0, among: all) } == [.topLeading, .topTrailing, .center, .bottomLeading, .bottomTrailing])
        // No car: a Y with the grid under the home.
        let noCar: [EnergyNode] = [.solar, .battery, .home, .grid]
        #expect(FlowPlan.spot(.grid, among: noCar) == .bottom)
        #expect(FlowPlan.spot(.solar, among: noCar) == .topLeading)
        // Only the sun and the grid: a straight line.
        let line: [EnergyNode] = [.solar, .home, .grid]
        #expect(FlowPlan.spot(.solar, among: line) == .top)
        #expect(FlowPlan.spot(.grid, among: line) == .bottom)
        // The axis needs more height than the corners.
        #expect(FlowPlan.least(all) == NowLayout.minFlow)
        #expect(FlowPlan.least(noCar) > NowLayout.minFlow)
        #expect(FlowPlan.least(line) == FlowPlan.least(noCar))
    }

    @Test func beamsRunStraightFromJustPastTheTextToJustOutsideTheRing() throws {
        let size = CGSize(width: 343, height: 224), w: CGFloat = 98, h: CGFloat = 70
        let hub = CGRect(x: size.width / 2 - 46, y: size.height / 2 - 46, width: 92, height: 92)
        let frames: [FlowPlan.Spot: CGRect] = [
            .topLeading: CGRect(x: 0, y: 0, width: w, height: h),
            .topTrailing: CGRect(x: size.width - w, y: 0, width: w, height: h),
            .bottomLeading: CGRect(x: 0, y: size.height - h, width: w, height: h),
            .bottomTrailing: CGRect(x: size.width - w, y: size.height - h, width: w, height: h),
        ]
        var lengths = [CGFloat]()
        for (spot, frame) in frames {
            let ends = try #require(FlowPlan.beam(node: frame, at: spot, hub: hub))
            // 8 pt outside the ring, on the line to its centre.
            #expect(abs(hypot(ends.hub.x - hub.midX, ends.hub.y - hub.midY) - (46 + FlowPlan.hubGap)) < 1e-6)
            // Clear of the node's text, on the hub's side of it.
            #expect(!frame.contains(ends.node))
            #expect(spot.onTop ? ends.node.y > frame.maxY : ends.node.y < frame.minY)
            #expect(ends.length >= FlowPlan.shortest)
            lengths.append(ends.length)
        }
        // All the same length, so the light reads the same on each.
        #expect((lengths.max() ?? 0) - (lengths.min() ?? 0) < 1e-6)
        // On the axis the beam is straight down.
        let top = CGRect(x: size.width / 2 - w / 2, y: 0, width: w, height: 60)
        let tall = CGRect(x: size.width / 2 - 46, y: 150 - 46, width: 92, height: 92)
        let axis = try #require(FlowPlan.beam(node: top, at: .top, hub: tall))
        #expect(abs(axis.node.x - axis.hub.x) < 1e-6)
        // No room, no beam.
        #expect(FlowPlan.beam(node: top, at: .top, hub: hub) == nil)
    }
}
