import Foundation
import FTWShared

/// From a site's readings to the energy diagram's nodes: the same corners,
/// the same colours by role and direction, the same rules as the box's own
/// dashboard, so a phone and the box page tell one story.
public enum Flow {
    /// Below this a node is idle: the box page's FLOW_IDLE_W, the same
    /// number as the site's grid tolerance.
    public static let idleW: Double = 42

    public enum Role: String, Sendable { case grid, pv, battery, ev, load }
    public enum Corner: Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    /// Colour meaning, not colour: the UI maps these to its palette.
    public enum Tone: Sendable { case muted, importing, exporting, solar, battery, charging, discharging, ev, house }

    public struct Node: Equatable, Sendable, Identifiable {
        public var id: String
        public var role: Role
        public var corner: Corner
        public var title: String
        public var name: String?
        /// Magnitude in kW, never signed for display.
        public var kw: Double
        /// Whether power flows toward the house.
        public var toHub: Bool
        public var tone: Tone
        public var sub: String
        public var socPct: Double?
        public var dailyParts: [(text: String, tone: Tone)]
        public var tappable: Bool

        public static func == (a: Node, b: Node) -> Bool {
            a.id == b.id && a.kw == b.kw && a.toHub == b.toHub && a.sub == b.sub && a.socPct == b.socPct && a.dailyParts.map(\.text) == b.dailyParts.map(\.text)
        }
    }

    public struct Readings: Equatable, Sendable {
        /// Core's qualified load, or nil when no load was sent.
        public var loadKw: Double?
        public var nodes: [Node]
        public var selfPoweredPctToday: Double?
    }

    static func idle(_ w: Double) -> Bool { abs(w) <= idleW }

    public static func tone(_ role: Role, _ watts: Double?) -> Tone {
        guard let w = watts else {
            switch role {
            case .grid, .pv: return .muted
            case .battery: return .battery
            case .ev: return .ev
            case .load: return .house
            }
        }
        switch role {
        case .grid: return idle(w) ? .muted : (w >= 0 ? .importing : .exporting)
        case .pv: return idle(w) ? .muted : .solar
        case .battery: return idle(w) ? .battery : (w >= 0 ? .charging : .discharging)
        case .ev: return idle(w) ? .ev : .charging
        case .load: return .house
        }
    }

    /// Nodes from the frozen fields on the 1 Hz stream. A field that never
    /// arrived is no node, except the grid: a site that cannot see its own
    /// meter is a gap the owner should see.
    public static func readings(fields: [Int: Double]) -> Readings {
        var nodes = [Node]()
        if let g = fields[Contract.FID.gridW] {
            nodes.append(Node(id: "grid", role: .grid, corner: .bottomLeft, title: "GRID", kw: abs(g) / 1000, toHub: g >= 0, tone: tone(.grid, g), sub: idle(g) ? "balanced" : (g >= 0 ? "importing" : "exporting"), dailyParts: [], tappable: true))
        } else {
            nodes.append(Node(id: "grid", role: .grid, corner: .bottomLeft, title: "GRID", kw: 0, toHub: true, tone: .muted, sub: "no data", dailyParts: [], tappable: false))
        }
        if let p = fields[Contract.FID.pvW] {
            nodes.append(Node(id: "pv", role: .pv, corner: .topLeft, title: "SOLAR", kw: -p / 1000, toHub: true, tone: tone(.pv, p), sub: "", dailyParts: [], tappable: true))
        }
        if let b = fields[Contract.FID.batteryW] {
            nodes.append(Node(id: "battery", role: .battery, corner: .topRight, title: "BATTERY", kw: abs(b) / 1000, toHub: b < 0, tone: tone(.battery, b), sub: idle(b) ? "idle" : (b >= 0 ? "charging" : "discharging"), socPct: fields[Contract.FID.batterySoc].map { ($0 / 10).rounded() }, dailyParts: [], tappable: true))
        }
        // No field, no node: an invented idle charger would misstate hardware.
        if let e = fields[Contract.FID.evW] {
            nodes.append(Node(id: "ev", role: .ev, corner: .bottomRight, title: "EV CHARGER", kw: e / 1000, toHub: false, tone: tone(.ev, e), sub: idle(e) ? "idle" : "charging", dailyParts: [], tappable: true))
        }
        return Readings(loadKw: fields[Contract.FID.loadW].map { $0 / 1000 }, nodes: nodes, selfPoweredPctToday: nil)
    }

    /// Nodes from GET /api/status: per-driver bubbles and energy today, the
    /// dashboard's own document.
    public static func readings(status: JSON) -> Readings {
        var nodes = [Node]()
        let today = status["energy"]?["today"]
        func kwh(_ key: String) -> Double { (today?[key]?.number ?? 0) / 1000 }
        let imp = kwh("import_wh"), exp = kwh("export_wh"), pvTotal = kwh("pv_wh"), loadTotal = kwh("load_wh")
        let charged = kwh("bat_charged_wh"), discharged = kwh("bat_discharged_wh")
        let gridDaily: [(String, Tone)] = [("↓ \(EnergyFormat.short(imp))", .importing), ("↑ \(EnergyFormat.short(exp))", .exporting)]
        let batDaily: [(String, Tone)] = [("↑ \(EnergyFormat.short(charged))", .charging), ("↓ \(EnergyFormat.short(discharged))", .discharging)]

        if let g = status["grid_w"]?.number {
            nodes.append(Node(id: "grid", role: .grid, corner: .bottomLeft, title: "GRID", kw: abs(g) / 1000, toHub: g >= 0, tone: tone(.grid, g), sub: idle(g) ? "balanced" : (g >= 0 ? "importing" : "exporting"), dailyParts: gridDaily.map { (text: $0.0, tone: $0.1) }, tappable: true))
        } else {
            nodes.append(Node(id: "grid", role: .grid, corner: .bottomLeft, title: "GRID", kw: 0, toHub: true, tone: .muted, sub: "no data", dailyParts: [], tappable: false))
        }

        for (name, d) in (status["drivers"]?.object ?? []).sorted(by: { $0.0 < $1.0 }) {
            let st = d["status"]?.string ?? ""
            guard st != "offline", st != "disabled", d["not_running"]?.bool != true else { continue }
            if let p = d["pv_w"]?.number {
                nodes.append(Node(id: "pv-\(name)", role: .pv, corner: .topLeft, title: "SOLAR", name: name, kw: -p / 1000, toHub: true, tone: tone(.pv, p), sub: "", dailyParts: [(text: "\(EnergyFormat.short(pvTotal)) kWh", tone: .solar)], tappable: true))
            }
            if let b = d["bat_w"]?.number {
                let observe = d["observe_only"]?.bool == true
                nodes.append(Node(id: "bat-\(name)", role: .battery, corner: .topRight, title: "BATTERY", name: name, kw: abs(b) / 1000, toHub: b < 0, tone: tone(.battery, b), sub: observe ? "observe only" : (idle(b) ? "idle" : (b >= 0 ? "charging" : "discharging")), socPct: d["bat_soc"]?.number.map { ($0 * 100).rounded() }, dailyParts: batDaily.map { (text: $0.0, tone: $0.1) }, tappable: !observe))
            }
            if let e = d["ev_w"]?.number {
                nodes.append(Node(id: "ev-\(name)", role: .ev, corner: .bottomRight, title: "EV CHARGER", name: name, kw: abs(e) / 1000, toHub: false, tone: tone(.ev, e), sub: idle(e) ? "idle" : "charging", dailyParts: [], tappable: true))
            }
        }
        let selfPowered: Double? = loadTotal > 0.001 ? max(0, min(100, (1 - imp / loadTotal) * 100)) : nil
        return Readings(loadKw: status["load_w"]?.number.map { $0 / 1000 }, nodes: nodes, selfPoweredPctToday: selfPowered)
    }

    /// Charger watts the box's HTTP API knows, summed.
    public static func loadpointChargeW(_ points: [Loadpoint]) -> Double {
        points.reduce(0) { $0 + ($1.powerW > idleW ? $1.powerW : 0) }
    }

    /// Add the charger's reading when the stream has no active EV field.
    /// Core owns the house load: keep it unchanged, including nil and zero.
    public static func withLoadpointEV(_ fields: [Int: Double], evW: Double) -> [Int: Double] {
        guard evW > idleW else { return fields }
        if let wire = fields[Contract.FID.evW], abs(wire) > idleW { return fields }
        var out = fields
        out[Contract.FID.evW] = evW.rounded()
        return out
    }

    // MARK: Beams on Now

    /// A figure on Now: 10 W steps under 1 kW, 0.1 kW to 10 kW, whole kW
    /// past that. It changes when the digits on screen change, so a figure
    /// rolls when it means something and not every second.
    public static func quantised(_ watts: Double) -> Double {
        guard watts.isFinite else { return 0 }
        return (watts / step(watts)).rounded() * step(watts)
    }

    /// The figure's step at a reading: 10 W, 100 W or 1 kW.
    static func step(_ watts: Double) -> Double {
        let a = abs(watts)
        return a < 995 ? 10 : (a < 9_950 ? 100 : 1_000)
    }

    /// A figure on Now that holds still on a rounding edge: the one shown
    /// stays until the reading moves more than 60 % of a step away from
    /// it, so 1.45 kW read as 1.5, 1.4 and 1.5 again shows 1.5 throughout.
    public static func quantised(_ watts: Double, holding shown: Double?) -> Double {
        let next = quantised(watts)
        guard let shown, shown.isFinite, watts.isFinite else { return next }
        return abs(watts - shown) > 0.6 * max(step(shown), step(watts)) ? next : shown
    }

    /// A beam's core width in points: 1.25 at rest, 1.1 more per kW, never
    /// past 6. At 1.1 kW it is as wide as a trace's line.
    public static func beamWidth(kw: Double) -> Double {
        min(6, max(1.25, 1.25 + 1.1 * abs(kw)))
    }

    /// How fast the light runs from source to sink, in points a second: 19
    /// at 0.1 kW, 31 at 1 kW, 52 at 10 kW. Faster with power, never racing.
    public static func waveSpeed(kw: Double) -> Double {
        16 + 22 * log10(1 + 4 * abs(kw))
    }

    /// Points from one crest of the light to the next.
    public static let wavelength: Double = 30

    /// Brightness along a beam, from 0.45 to 1: soft crests a wavelength
    /// apart. `s` is points from the source, `phase` is wavelengths the
    /// light has travelled.
    public static func wave(_ s: Double, phase: Double) -> Double {
        let c = (1 + cos(2 * .pi * (s / wavelength - phase))) / 2
        return 0.45 + 0.55 * c * c * c
    }

    /// A value that follows its target as a critically damped spring with
    /// time constant `tau`: it swells to a new value and never overshoots.
    /// Stepped exactly, so a long frame lands where many short ones would.
    public struct Follow: Equatable, Sendable {
        public private(set) var value: Double
        public private(set) var velocity: Double = 0

        public init(_ value: Double) { self.value = value }

        public mutating func step(toward target: Double, dt: Double, tau: Double) {
            guard dt > 0 else { return }
            guard tau > 0 else { return snap(target) }
            let w = 1 / tau, e = value - target, k = exp(-w * dt)
            let a = velocity + w * e
            value = target + (e + a * dt) * k
            velocity = (velocity - w * a * dt) * k
        }

        public mutating func snap(_ target: Double) {
            value = target
            velocity = 0
        }
    }

    /// The phosphor on a beam, from 0 (ink, still) to 1 (live). It ignites
    /// on the first live frame with the app's spring (response 0.35 s,
    /// bounce 0.15), and when live ends it decays exponentially (τ 0.4 s)
    /// while its wave slows to rest in 0.35 s, so the screen cools like a
    /// CRT. A beam that has never been live stays at 0. Instant under
    /// Reduce Motion.
    public struct Light: Equatable, Sendable {
        public static let decay: Double = 0.4
        public static let rest: Double = 0.35
        /// `Theme.spring`: `Spring(duration: 0.35, bounce: 0.15)` is a
        /// response of 0.35 s at damping 1 − bounce.
        static let response: Double = 0.35
        static let damping: Double = 0.85

        public private(set) var live: Bool
        private var since: Double
        private var level0: Double
        private var motion0: Double

        public init(live: Bool, at t: Double) {
            self.live = live
            since = t
            level0 = live ? 1 : 0
            motion0 = level0
        }

        public mutating func set(live: Bool, at t: Double, instant: Bool = false) {
            guard live != self.live else { return }
            let target: Double = live ? 1 : 0
            level0 = instant ? target : level(at: t)
            motion0 = instant ? target : motion(at: t)
            since = t
            self.live = live
        }

        /// The glow, the wave's depth and the core's strength.
        public func level(at t: Double) -> Double {
            let dt = max(0, t - since)
            return live ? 1 - (1 - level0) * Self.residual(dt) : level0 * exp(-dt / Self.decay)
        }

        /// How fast the wave runs, as a share of its speed.
        public func motion(at t: Double) -> Double {
            let dt = max(0, t - since)
            if live { return min(1, 1 - (1 - motion0) * Self.residual(dt)) }
            let k = 1 - min(1, dt / Self.rest)
            return motion0 * k * k
        }

        /// What is left of a step after `t` seconds on the spring.
        static func residual(_ t: Double) -> Double {
            let w = 2 * Double.pi / response, z = damping
            let wd = w * (1 - z * z).squareRoot()
            return exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
        }
    }

    /// What a beam on Now shows for one node's reading. Only a reading the
    /// box confirmed live glows or moves; at 42 W or less the beam is a
    /// still dotted hairline.
    public struct BeamTarget: Equatable, Sendable {
        public let node: EnergyNode
        /// Magnitude, never signed.
        public let kw: Double
        public let live: Bool
        public let flowing: Bool
        /// The light runs toward the home.
        public let towardHome: Bool

        public init(node: EnergyNode, kw: Double, live: Bool, flowing: Bool, towardHome: Bool) {
            self.node = node
            self.kw = kw
            self.live = live
            self.flowing = flowing
            self.towardHome = towardHome
        }

        public init(_ r: NodeReading) {
            self.init(node: r.node, kw: (r.watts ?? 0) / 1000, live: r.freshness.live, flowing: r.flowing, towardHome: r.towardHome)
        }
    }

    /// One beam's look in one frame.
    public struct BeamFrame: Equatable, Sendable {
        /// The core's width, in points.
        public var width: Double
        /// Wavelengths the light has run, source to sink.
        public var phase: Double
        /// The phosphor: the glow's strength and the wave's depth.
        public var light: Double
        /// 0 for a beam, 1 for the still dotted hairline of a node at rest.
        public var idle: Double

        /// The core's opacity: 0.35 in ink, full while live.
        public var alpha: Double { 0.35 + 0.65 * min(1, light) }
        /// How far the light's wave dips, 0 (even) to 1.
        public var depth: Double { min(1, light) }
    }

    /// A beam over time: its width and speed follow the readings (τ 0.4 s),
    /// its light ignites and decays, its wave runs at the speed the power
    /// gives. A plain value stepped once per frame, so a test can run it.
    public struct BeamMotion: Equatable, Sendable {
        public static let tau: Double = 0.4

        private var width: Follow
        private var speed: Follow
        private var idle: Follow
        private var light: Light
        private var phase: Double = 0
        private var last: Double

        /// The first frame: everything where the reading puts it, with no
        /// ignite, so a screen that opens on live data does not flash and a
        /// cache never glows.
        public init(_ target: BeamTarget, at t: Double) {
            width = Follow(Flow.beamWidth(kw: target.kw))
            speed = Follow(Flow.waveSpeed(kw: target.kw))
            idle = Follow(target.flowing ? 0 : 1)
            light = Light(live: target.live, at: t)
            last = t
        }

        /// The beam at `t`. Under Reduce Motion it snaps and its light does
        /// not run.
        /// Longer than this between two frames, nothing was drawn: the
        /// screen was away or the timeline rested.
        public static let gap: Double = 0.5

        public mutating func step(_ target: BeamTarget, at t: Double, reduceMotion: Bool) -> BeamFrame {
            let dt = max(0, t - last)
            last = max(last, t)
            // A reading that stopped being live while nothing was drawn went
            // out at a moment nobody saw, so its glow is already gone: it
            // never cools on screen afterwards. Igniting still plays.
            light.set(live: target.live, at: t, instant: reduceMotion || (!target.live && dt > Self.gap))
            let w = Flow.beamWidth(kw: target.kw), v = Flow.waveSpeed(kw: target.kw), rest: Double = target.flowing ? 0 : 1
            if reduceMotion {
                width.snap(w)
                speed.snap(v)
                idle.snap(rest)
            } else {
                width.step(toward: w, dt: dt, tau: Self.tau)
                speed.step(toward: v, dt: dt, tau: Self.tau)
                idle.step(toward: rest, dt: dt, tau: Self.tau / 2)
                phase = (phase + speed.value * light.motion(at: t) * dt / Flow.wavelength).truncatingRemainder(dividingBy: 1_000)
            }
            return BeamFrame(width: width.value, phase: phase, light: light.level(at: t), idle: min(1, max(0, idle.value)))
        }
    }

    // MARK: The ring on Now

    /// How much of its quarter of the ring a node's arc lights, from its
    /// power: none at rest, a fifth at 0.6 kW, half at 1.8 kW, nine tenths
    /// at 6 kW. One curve for every node, so arcs compare across the ring,
    /// and it saturates, so an 11 kW charger never swallows the rest.
    public static func ringFill(kw: Double) -> Double {
        let a = abs(kw)
        guard a.isFinite, a * 1_000 > idleW else { return 0 }
        return min(1, max(0.12, 1 - exp(-a / 2.5)))
    }

    /// One arc of the ring over time: its beam's light, wave and rest
    /// (`BeamMotion`), and how much of its quarter it lights, which swells
    /// to a new reading like a beam's width does.
    public struct RingMotion: Equatable, Sendable {
        private var beam: BeamMotion
        private var fill: Follow
        private var last: Double

        public init(_ target: BeamTarget, at t: Double) {
            beam = BeamMotion(target, at: t)
            fill = Follow(Flow.ringFill(kw: target.kw))
            last = t
        }

        public mutating func step(_ target: BeamTarget, at t: Double, reduceMotion: Bool) -> RingFrame {
            let dt = max(0, t - last)
            last = max(last, t)
            let f = beam.step(target, at: t, reduceMotion: reduceMotion)
            let wanted = Flow.ringFill(kw: target.kw)
            if reduceMotion { fill.snap(wanted) } else { fill.step(toward: wanted, dt: dt, tau: BeamMotion.tau) }
            return RingFrame(beam: f, fill: min(1, max(0, fill.value)))
        }
    }

    /// One arc's look in one frame.
    public struct RingFrame: Equatable, Sendable {
        public var beam: BeamFrame
        /// The share of its quarter the arc lights, 0 to 1.
        public var fill: Double
    }

    // MARK: The fuse

    public struct Phase: Equatable, Sendable, Identifiable {
        public let label: String
        public let amps: Double
        public let watts: Double
        public let pct: Double
        public let exporting: Bool
        public var id: String { label }
    }

    public struct Fuse: Equatable, Sendable {
        public let maxAmps: Double
        public let phases: [Phase]
        public let fallback: (amps: Double, pct: Double)?

        public static func == (a: Fuse, b: Fuse) -> Bool {
            a.maxAmps == b.maxAmps && a.phases == b.phases && a.fallback?.amps == b.fallback?.amps
        }
    }

    /// Per phase when the meter reports amps; otherwise one bar from grid,
    /// PV and battery throughput, as the box page does.
    public static func fuse(status: JSON) -> Fuse? {
        guard let f = status["fuse"], let maxAmps = f["max_amps"]?.number, maxAmps > 0 else { return nil }
        let n = max(1, min(3, Int((f["phases"]?.number ?? 3).rounded())))
        let voltage = f["voltage"]?.number ?? 230
        let amps = (status["phase_amps"]?.array ?? []).map { $0.number ?? 0 }
        let watts = (status["phase_powers"]?.array ?? []).map { $0.number ?? 0 }
        if !amps.isEmpty {
            let phases = (0..<n).map { i -> Phase in
                let a = i < amps.count ? amps[i] : 0
                return Phase(label: "L\(i + 1)", amps: a, watts: i < watts.count ? watts[i] : 0, pct: min(100, abs(a) / maxAmps * 100), exporting: a < -0.1)
            }
            return Fuse(maxAmps: maxAmps, phases: phases, fallback: nil)
        }
        let grid = abs(status["grid_w"]?.number ?? 0)
        let pv = abs(status["pv_w"]?.number ?? 0)
        let bat = status["bat_w"]?.number ?? 0
        let throughput = max(grid, pv + (bat < 0 ? -bat : 0))
        let a = throughput / voltage / Double(n)
        return Fuse(maxAmps: maxAmps, phases: [], fallback: (a, min(100, a / maxAmps * 100)))
    }
}
