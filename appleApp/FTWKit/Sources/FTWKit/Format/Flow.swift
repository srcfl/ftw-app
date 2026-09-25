import Foundation

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
        public var loadKw: Double
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
        return Readings(loadKw: (fields[Contract.FID.loadW] ?? 0) / 1000, nodes: nodes, selfPoweredPctToday: nil)
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
        return Readings(loadKw: (status["load_w"]?.number ?? 0) / 1000, nodes: nodes, selfPoweredPctToday: selfPowered)
    }

    /// Charger watts the box's HTTP API knows, summed.
    public static func loadpointChargeW(_ points: [Loadpoint]) -> Double {
        points.reduce(0) { $0 + ($1.powerW > idleW ? $1.powerW : 0) }
    }

    /// Put the car on its own node when the 1 Hz stream folded it into the
    /// house. A box that already sends field 10 is left alone.
    public static func withLoadpointEV(_ fields: [Int: Double], evW: Double) -> [Int: Double] {
        guard evW > idleW else { return fields }
        if let wire = fields[Contract.FID.evW], abs(wire) > idleW { return fields }
        var out = fields
        out[Contract.FID.evW] = evW.rounded()
        out[Contract.FID.loadW] = max(0, (fields[Contract.FID.loadW] ?? 0) - evW)
        return out
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
