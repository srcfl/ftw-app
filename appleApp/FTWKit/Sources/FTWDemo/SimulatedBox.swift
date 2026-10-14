import Foundation
import FTWKit

/// A box that lives in this process: the other end of the protocol, for the
/// demo and for the tests. It speaks frames exactly as a box does, holds a
/// `SimulatedHouse`, and answers the same routes and commands the app uses.
///
/// It is not the box and says so: the demo runs behind its own band and
/// writes nothing to disk.
@MainActor
public final class SimulatedBox {
    public let house: SimulatedHouse
    let scheduler: Scheduler
    private let requireStepUp: Bool
    private let bootedAtMs: Double

    /// Frames to the app.
    public var send: (@MainActor (Bytes) -> Void)?

    private var subscription: Subscription?
    private var telemetry: Cancellable?
    private var seq: UInt64 = 0
    private var controlRev: UInt64 = 1
    private var lastSent: [Int: Double] = [:]
    public var booting = false
    /// Silence instead of answers, to test the app's deadlines.
    public var mute = false
    /// Ack commands but never report a result.
    public var neverConfirm = false
    /// How long the box takes from ack to result: the demo waits as a
    /// charger write does, so the receipt has a moment to show.
    public var resultDelayMs: Double = 0
    /// Holds one closed tile of the first history answer back this long,
    /// then sends it, as a slow box would: the app bridges the gap with an
    /// estimate meanwhile and the data grows into it. 0 sends all at once.
    public var holdTileMs: Double = 0
    private var heldTile = false
    /// The plan as last made, with the quarter and revision it was made
    /// for. Core plans each quarter and sends the same plan until the next.
    var madePlan: (quarter: Double, rev: UInt64, plan: Plan)?
    /// The share of today the box has prices for, as
    /// `priced_coverage_pct`. Below 0.95 the grid widget marks its cost
    /// partial.
    public var pricedShare: Double = 1
    /// A Core with srcfl/ftw#1586 reads and sends the ready time as
    /// `time_of_day_min` on the household clock. Off, it is a Core that
    /// knows only `time_of_day_min_utc`.
    public var readsHouseholdClock = true
    /// The last schedule body the app sent, as sent.
    public private(set) var lastScheduleBody: JSON?
    /// The box the demo is showing, for the demo's own controls (plug the
    /// car in or out). Nil outside the demo.
    public private(set) static weak var current: SimulatedBox?
    public private(set) var receivedCommands: [String] = []
    /// Every API request, as "METHOD /path", so a test can count reads.
    public private(set) var receivedRequests: [String] = []
    /// Every request frame in the order it came: `hist.query`, `plan.get`,
    /// `price.get`, and each API request as "METHOD /path".
    public private(set) var asks: [String] = []
    public private(set) var stepUpsSeen = 0

    public nonisolated static let modes: [ModeInfo] = [
        ModeInfo(key: "planner_passive_arbitrage", label: "Passive arbitrage", tooltip: "Charge from the cheapest available source (PV when sunny, grid during cheap hours). Never exports from battery.", tier: "primary"),
        ModeInfo(key: "planner_arbitrage", label: "Active arbitrage", tooltip: "Full price arbitrage — charge cheap, discharge into expensive hours (battery may export to grid).", tier: "primary"),
        ModeInfo(key: "idle", label: "Stop batteries", tooltip: "Hold every battery at 0 W for as long as this mode is on.", tier: "advanced"),
        ModeInfo(key: "self_consumption", label: "Self (manual)", tooltip: "Manual self-consumption — PI chases grid target, no plan.", tier: "advanced"),
        ModeInfo(key: "peak_shaving", label: "Peak", tooltip: "Limit grid import to the configured peak limit.", tier: "advanced"),
        ModeInfo(key: "charge", label: "Charge", tooltip: "Force full charge regardless of price.", tier: "advanced"),
        ModeInfo(key: "planner_self", label: "Planner (self)", tooltip: "Forecast-driven self-consumption.", tier: "hidden"),
    ]

    /// What a box with a meter, an inverter, a battery and a charger
    /// offers. Registry names only; `ContractTests` checks.
    public nonisolated static let caps = [
        "status.core", "status.drivers", "history.5m", "history.1h", "history.etag", "cmd.lease",
        "cmd.readback", "der.battery", "der.ev", "plan.dispatch", "price.spot", "api.passthrough",
    ]

    public init(scheduler: Scheduler, house: SimulatedHouse = SimulatedHouse(), requireStepUp: Bool = false, uptimeAtStartMs: Double = 3_600_000) {
        self.scheduler = scheduler
        self.house = house
        self.requireStepUp = requireStepUp
        bootedAtMs = scheduler.nowMs - uptimeAtStartMs
        house.step(nowMs: scheduler.nowMs, dtMs: 1_000)
    }

    var uptimeMs: Double { scheduler.nowMs - bootedAtMs }

    /// Move the house and send what a box would send for that second.
    public func tick(_ dtMs: Double = 1_000) {
        house.step(nowMs: scheduler.nowMs, dtMs: dtMs)
    }

    public func stop() {
        telemetry?.cancel()
        telemetry = nil
        send = nil
    }

    // MARK: Frames in

    public func receive(_ bytes: Bytes) {
        if mute { return }
        guard let frame = try? Frame.decode(bytes) else { return }
        let env = frame.envelope
        let body = env.b ?? CBOR.emptyMap
        if ["price.get", "hist.query", "plan.get"].contains(env.t) { asks.append(env.t) }
        switch env.t {
        case "hello": onHello(body)
        case "sub":
            let first = subscription == nil
            subscription = Subscription(bucket: body["bucket"]?.int ?? 512, hz: body["hz"]?.double ?? 1)
            if first { sendSnap() }
            restartTelemetry()
        case "price.get":
            // The box decodes times into int64 and drops a body with a
            // fraction in one, answering nothing. So does this.
            guard let from = Self.wholeMs(body["fromMs"]), let to = Self.wholeMs(body["toMs"]) else { return }
            sendBulk(Envelope(t: "price", id: env.id, b: pricesCBOR(from: from, to: to)))
        case "hist.query":
            // The box refuses a malformed query by name and answers the rest
            // tile by tile, then once more to say it is done.
            guard let q = HistQuery(cbor: body), !q.series.isEmpty, q.toMs > q.fromMs else {
                refuse(env.id, "E_UNKNOWN_OP", [("t", .text("hist.query"))])
                return
            }
            var chunks = historyTiles(q)
            var held: HistChunk?
            if holdTileMs > 0, !heldTile, chunks.count >= 3 {
                // A closed tile in the middle, so measured data sits on
                // both sides of it.
                heldTile = true
                held = chunks.remove(at: chunks.count - 2)
            }
            for chunk in chunks { sendBulk(Envelope(t: "hist.chunk", id: env.id, b: chunk.wire)) }
            let end = Envelope(t: "hist.end", id: env.id, b: HistEnd(resActual: q.res, gaps: []).wire)
            if let held {
                scheduler.after(holdTileMs) { [weak self] in
                    self?.sendBulk(Envelope(t: "hist.chunk", id: env.id, b: held.wire))
                    self?.sendBulk(end)
                }
            } else {
                sendBulk(end)
            }
        case "plan.get":
            sendBulk(Envelope(t: "plan", id: env.id, b: sessionPlan().wire))
        case "api.req": onAPI(env.id, body)
        case "cmd": onCommand(body)
        default: break
        }
    }

    /// An integer, as Go's int64 decoding demands; a float is refused.
    static func wholeMs(_ c: CBOR?) -> Double? {
        switch c {
        case .unsigned(let u)?: return Double(u)
        case .negative(let n)?: return -1 - Double(n)
        default: return nil
        }
    }

    private func onHello(_ body: CBOR) {
        let wantsSub = body["sub"]
        var pairs: [(String, CBOR)] = [
            ("proto", .int(Proto.max)),
            ("mode", .text(booting ? "booting" : "full")),
            ("box", .map([("id", .text("demo-box")), ("build", .text("0.131.0-demo")), ("tz", .text(house.timeZone.identifier))])),
            ("clock", .map([("source", .text("ntp")), ("syncedAtMs", .number(scheduler.nowMs - 60_000)), ("uptimeMs", .number(uptimeMs))])),
            ("caps", .array(Self.caps.map { .text($0) })),
            ("capsHash", .text("demo")),
            ("modes", .array(Self.modes.map { .map([("key", .text($0.key)), ("label", .text($0.label)), ("tooltip", .text($0.tooltip)), ("tier", .text($0.tier))]) })),
            ("role", .text(Contract.roleOwner)),
            ("scopes", .array(Contract.scopes.map { .text($0) })),
        ]
        if booting {
            pairs.append(("boot", .map([("phase", .text("vacuum")), ("pct", .int(40)), ("etaMs", .null)])))
        } else if let sub = wantsSub, sub.entries != nil {
            pairs.append(("subscribed", .bool(true)))
        }
        sendBulk(Envelope(t: "hello_ok", b: .map(pairs)))
        if !booting, let sub = wantsSub, sub.entries != nil {
            subscription = Subscription(bucket: sub["bucket"]?.int ?? 512, hz: sub["hz"]?.double ?? 1)
            sendSnap()
            restartTelemetry()
        }
    }

    // MARK: Telemetry

    var fields: [Int: Double] {
        var f: [Int: Double] = [
            Contract.FID.mode: Double(Self.modes.firstIndex { $0.key == house.modeKey } ?? 0),
            Contract.FID.gridW: house.gridW,
            Contract.FID.pvW: house.pvW,
            Contract.FID.batteryW: house.batteryW,
            Contract.FID.batterySoc: (house.socFraction * 1000).rounded(),
            // The house alone, as Core sends it: grid − battery − solar −
            // car. The car is its own field.
            Contract.FID.loadW: house.baseLoadW,
        ]
        f[Contract.FID.evW] = house.evWatts
        return f
    }

    private func sourcesCBOR() -> CBOR {
        let now = uptimeMs
        func src(_ kind: String, _ name: String) -> CBOR {
            .map([("kind", .text(kind)), ("name", .text(name)), ("lastOkMs", .number(now - 400)), ("staleAfterMs", .int(10_000)), ("state", .text("live"))])
        }
        // Keyed by driver, as Core keys them: a meter, a hybrid inverter with
        // the battery, a second inverter on the garage roof, and the charger.
        return .map([("sdm630", src("meter", "sdm630")), ("sungrow", src("inverter", "sungrow")), ("fronius", src("inverter", "fronius")), ("easee", src("charger", "easee"))])
    }

    private func sendSnap() {
        let f = fields
        lastSent = f
        let dict: [(String, CBOR)] = [
            ("1", .map([("name", .text("mode")), ("unit", .null), ("srcId", .null)])),
            ("2", .map([("name", .text("grid_w")), ("unit", .text("W")), ("srcId", .text("sdm630"))])),
            ("3", .map([("name", .text("pv_w")), ("unit", .text("W")), ("srcId", .text("sungrow"))])),
            ("4", .map([("name", .text("battery_w")), ("unit", .text("W")), ("srcId", .text("sungrow"))])),
            ("5", .map([("name", .text("battery_soc")), ("unit", .text("permille")), ("srcId", .text("sungrow"))])),
            ("6", .map([("name", .text("load_w")), ("unit", .text("W")), ("srcId", .text("sdm630"))])),
            ("10", .map([("name", .text("ev_w")), ("unit", .text("W")), ("srcId", .text("easee"))])),
        ]
        sendBulk(Envelope(t: "snap", b: .map([
            ("uptimeMs", .number(uptimeMs)),
            ("controlRev", .unsigned(controlRev)),
            ("dict", .map(dict)),
            ("fields", .map(f.sorted { $0.key < $1.key }.map { (String($0.key), CBOR.number($0.value)) })),
            ("sources", sourcesCBOR()),
            ("dispatchBlockedBy", .array([])),
        ])))
    }

    private func restartTelemetry() {
        telemetry?.cancel()
        guard let sub = subscription else { return }
        let period = 1_000 / max(0.01, sub.hz)
        func loop() {
            telemetry = scheduler.after(period) { [weak self] in
                guard let self, self.send != nil else { return }
                self.tick(period)
                self.sendTelemetry()
                loop()
            }
        }
        loop()
    }

    /// A delta when something moved, a tick when nothing did: the same size
    /// and cadence either way.
    func sendTelemetry() {
        guard let sub = subscription, !mute else { return }
        seq += 1
        let f = fields
        let changed = f.filter { lastSent[$0.key] != $0.value }.sorted { $0.key < $1.key }
        lastSent = f
        let env: Envelope
        if changed.isEmpty {
            env = Envelope(t: "tick", b: .map([("seq", .unsigned(seq)), ("uptimeMs", .number(uptimeMs))]))
        } else {
            env = Envelope(t: "delta", b: .map([
                ("seq", .unsigned(seq)),
                ("uptimeMs", .number(uptimeMs)),
                ("fields", .map(changed.map { (String($0.key), CBOR.number($0.value)) })),
            ]))
        }
        if let frame = try? Frame.encode(lane: Frame.laneControl, envelope: env, bucket: sub.bucket) {
            send?(frame)
        }
    }

    // MARK: Prices

    func pricesCBOR(from: Double, to: Double) -> CBOR {
        let slotMs: Double = 3_600_000
        // Tomorrow's rates publish at 13:00 local.
        let midnight = scheduler.nowMs - house.hourOfDay(scheduler.nowMs) * 3_600_000
        let published = midnight + (house.hourOfDay(scheduler.nowMs) >= 13 ? 48 : 24) * 3_600_000
        let end = min(to, published)
        var slots = [CBOR]()
        var t = (from / slotMs).rounded(.down) * slotMs
        while t < end {
            let total = house.priceAt(t)
            slots.append(.map([("startMs", .number(t)), ("durationMs", .number(slotMs)), ("spotMinor", .number((total * 0.6).rounded())), ("totalMinor", .number(total))]))
            t += slotMs
        }
        return .map([("zone", .text("SE3")), ("currency", .text("SEK")), ("slots", .array(slots)), ("stale", .bool(end < to))])
    }

    // MARK: Commands

    private func onCommand(_ body: CBOR) {
        let cmdId = body["cmdId"]?.string ?? ""
        let op = body["op"]?.string ?? ""
        let args = body["args"] ?? CBOR.emptyMap
        receivedCommands.append(op)
        if let notAfter = body["notValidAfterMs"]?.double, notAfter < uptimeMs {
            result(cmdId, "expired", error: ("E_CMD_EXPIRED", []))
            return
        }
        sendControl(Envelope(t: "cmd.ack", b: .map([("cmdId", .text(cmdId)), ("leaseId", .text("lease-\(cmdId.prefix(8))")), ("expiresAtMs", .number(uptimeMs + 60_000))])))
        if neverConfirm { return }
        if resultDelayMs > 0 {
            scheduler.after(resultDelayMs) { [weak self] in self?.act(cmdId, op, args) }
        } else {
            act(cmdId, op, args)
        }
    }

    private func act(_ cmdId: String, _ op: String, _ args: CBOR) {
        switch op {
        case Contract.opSetMode:
            guard let mode = args["mode"]?.string, Self.modes.contains(where: { $0.key == mode }) else {
                result(cmdId, "rejected", error: ("E_PRECONDITION", []))
                return
            }
            house.modeKey = mode
            // Choosing one of the two plans says whether the battery sells.
            if mode == "planner_arbitrage" { house.batteryExport = "allowed" }
            if mode == "planner_passive_arbitrage" { house.batteryExport = "not_allowed" }
            controlRev += 1
            result(cmdId, "applied", observed: Double(Self.modes.firstIndex { $0.key == mode } ?? 0))
            // Core sends the plan after an applied command on the session.
            sendBulk(Envelope(t: "plan", b: sessionPlan().wire))
        case Contract.opPlannerPrefsSet:
            let k = args["safety_k"]?.double
            let export = args["battery_export"]?.string
            guard k != nil || export != nil, export.map({ ["unknown", "not_allowed", "allowed"].contains($0) }) ?? true else {
                result(cmdId, "rejected", error: ("E_UNKNOWN_OP", [("op", .text(op))]))
                return
            }
            if let k { house.safetyK = max(0, min(2, k)) }
            if let export { house.batteryExport = export }
            // A planner mode follows the prefs; a manual one is left alone.
            if house.modeKey.hasPrefix("planner_") {
                house.modeKey = house.batteryExport == "allowed" ? "planner_arbitrage" : "planner_passive_arbitrage"
            }
            controlRev += 1
            result(cmdId, "applied", observed: house.safetyK)
            sendBulk(Envelope(t: "plan", b: sessionPlan().wire))
        case Contract.opLoadpointHold:
            if args["clear"]?.bool == true {
                house.manualHoldW = nil
            } else {
                house.manualHoldW = args["power_w"]?.double ?? 0
            }
            result(cmdId, "applied", observed: house.manualHoldW ?? 0)
        case Contract.opLoadpointBoost:
            if args["cancel"]?.bool == true {
                house.boostUntilMs = nil
                house.lastBoostStop = "cancelled"
            } else if house.manualHoldW != nil || house.surplusOnly {
                result(cmdId, "rejected", error: ("E_UNAVAILABLE", [("op", .text(op))]))
                return
            } else {
                house.boostReserve = (args["min_battery_soc_pct"]?.double ?? 30) / 100
                house.boostUntilMs = scheduler.nowMs + (args["duration_s"]?.double ?? 3_600) * 1000
            }
            result(cmdId, "applied")
        case Contract.opLoadpointSocSet:
            guard house.carPluggedIn else {
                result(cmdId, "rejected", error: ("E_UNAVAILABLE", [("op", .text(op)), ("reason", .text("unplugged"))]))
                return
            }
            house.carSocFraction = max(0, min(1, args["soc"]?.double ?? house.carSocFraction))
            house.carSocSource = "inferred"
            house.carReportedAtMs = house.carReportedAtMs.map { min($0, scheduler.nowMs - 1) }
            result(cmdId, "applied", observed: house.carSocFraction)
        case Contract.opLoadpointSurplusOnlySet:
            house.surplusOnly = args["surplus_only"]?.bool ?? false
            result(cmdId, "applied", observed: house.surplusOnly ? 1 : 0)
        default:
            result(cmdId, "rejected", error: ("E_UNKNOWN_OP", []))
        }
    }

    private func result(_ cmdId: String, _ state: String, observed: Double? = nil, error: (String, [(String, CBOR)])? = nil) {
        var pairs: [(String, CBOR)] = [("cmdId", .text(cmdId)), ("state", .text(state))]
        if let observed { pairs.append(("observed", .map([("value", .number(observed)), ("src", .text("core")), ("uptimeMs", .number(uptimeMs))]))) }
        if let error { pairs.append(("error", .map([("code", .text(error.0)), ("args", .map(error.1))]))) }
        sendControl(Envelope(t: "cmd.result", b: .map(pairs)))
    }

    // MARK: The box's own API

    enum Tier { case read, configure, actuate, local }

    /// Priced beside the route, never from the method, as the box does.
    static let routes: [(method: String, path: String, tier: Tier, op: String?)] = [
        ("GET", "/api/status", .read, nil),
        ("GET", "/api/energy/daily", .read, nil),
        ("GET", "/api/savings/daily", .read, nil),
        ("GET", "/api/loadpoints", .read, nil),
        ("GET", "/api/mpc/plan", .read, nil),
        ("GET", "/api/planner/prefs", .read, nil),
        ("GET", "/api/energy/history", .read, nil),
        ("POST", "/api/planner/prefs", .actuate, Contract.opPlannerPrefsSet),
        ("POST", "/api/loadpoints/{id}/vehicle", .configure, nil),
        ("PUT", "/api/loadpoints/{id}/schedule", .configure, nil),
        ("DELETE", "/api/loadpoints/{id}/schedule", .configure, nil),
        ("POST", "/api/loadpoints/{id}/soc", .actuate, Contract.opLoadpointSocSet),
        ("POST", "/api/mode", .actuate, Contract.opSetMode),
        ("GET", "/api/config", .local, nil),
        ("GET", "/api/support/dump", .local, nil),
    ]

    static func match(_ method: String, _ path: String) -> (tier: Tier, op: String?, pattern: String, id: String?)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        for r in routes where r.method == method {
            let want = r.path.split(separator: "/", omittingEmptySubsequences: false)
            guard want.count == parts.count else { continue }
            var id: String?
            var ok = true
            for (a, b) in zip(want, parts) {
                if a == "{id}" { id = String(b).removingPercentEncoding } else if a != b { ok = false; break }
            }
            if ok { return (r.tier, r.op, r.path, id) }
        }
        return nil
    }

    private func onAPI(_ id: UInt32?, _ body: CBOR) {
        let method = body["method"]?.string ?? "GET"
        let path = body["path"]?.string ?? ""
        let stepUp = body["stepUp"]?.bool == true
        var query = [String: String]()
        for e in body["query"]?.entries ?? [] { if let k = e.key.string, let v = e.value.string { query[k] = v } }
        let requestBody = body["body"]?.byteString.flatMap { try? JSON(parsing: $0) }
        receivedRequests.append("\(method) \(path)")
        asks.append("\(method) \(path)")

        guard path.hasPrefix("/api/"), let route = Self.match(method, path) else {
            refuse(id, "E_UNKNOWN_OP", [])
            return
        }
        switch route.tier {
        case .local:
            refuse(id, "E_LOCAL_ONLY", [])
            return
        case .actuate:
            refuse(id, "E_USE_CMD", route.op.map { [("op", .text($0))] } ?? [])
            return
        case .configure:
            if stepUp { stepUpsSeen += 1 }
            if requireStepUp && !stepUp {
                refuse(id, "E_NEEDS_STEP_UP", [])
                return
            }
        case .read:
            break
        }
        let (status, json) = answer(method, route.pattern, route.id, query, requestBody)
        respond(id, status: status, json: json)
    }

    private func answer(_ method: String, _ pattern: String, _ itemID: String?, _ query: [String: String], _ body: JSON?) -> (Int, JSON) {
        let now = scheduler.nowMs
        switch (method, pattern) {
        case ("GET", "/api/status"):
            let perPhase = house.gridW / 3
            return (200, [
                "grid_w": .number(house.gridW), "pv_w": .number(house.pvW), "bat_w": .number(house.batteryW),
                "load_w": .number(house.baseLoadW),
                "energy": ["today": [
                    "import_wh": .number(house.todayImportWh), "export_wh": .number(house.todayExportWh),
                    "pv_wh": .number(house.todayPVWh), "load_wh": .number(house.todayLoadWh),
                    "bat_charged_wh": .number(house.todayChargedWh), "bat_discharged_wh": .number(house.todayDischargedWh),
                ]],
                "drivers": [
                    "sdm630": ["status": "ok", "meter_w": .number(house.gridW)],
                    "sungrow": ["status": "ok", "pv_w": .number((house.pvW * 0.62).rounded()), "bat_w": .number(house.batteryW), "bat_soc": .number(house.socFraction)],
                    "fronius": ["status": "ok", "pv_w": .number(house.pvW - (house.pvW * 0.62).rounded())],
                    "easee": ["status": "ok", "ev_w": .number(house.evWatts)],
                ],
                "fuse": ["max_amps": .number(house.fuseAmps), "phases": 3, "voltage": 230],
                "phase_amps": .array((0..<3).map { .number(((perPhase + Double($0) * 90) / 230 * 10).rounded() / 10) }),
                "phase_powers": .array((0..<3).map { .number((perPhase + Double($0) * 90).rounded()) }),
            ])
        case ("GET", "/api/energy/daily"):
            let days = max(1, min(90, Int(query["days"] ?? "7") ?? 7))
            let rows: [JSON] = (0..<days).reversed().map { offset in
                let l = house.ledger(dayOffset: offset, nowMs: now)
                return [
                    "day": .string(house.localDay(now - Double(offset) * 86_400_000)),
                    "load_wh": .number(l.load), "pv_wh": .number(l.pv), "import_wh": .number(l.imp),
                    "export_wh": .number(l.exp), "bat_charged_wh": .number(l.charged), "bat_discharged_wh": .number(l.discharged),
                ]
            }
            return (200, ["days": .array(rows)])
        case ("GET", "/api/savings/daily"):
            let days = max(1, min(90, Int(query["days"] ?? "7") ?? 7))
            let rows: [JSON] = (0..<days).reversed().map { savingsRow(dayOffset: $0, nowMs: now) }
            return (200, ["days": .array(rows), "tz": .string(house.timeZone.identifier), "value_scope": "site_total"])
        case ("GET", "/api/loadpoints"):
            return (200, ["enabled": true, "loadpoints": [loadpointJSON()]])
        case ("GET", "/api/planner/prefs"):
            let mapped = house.batteryExport == "allowed" ? "planner_arbitrage" : "planner_passive_arbitrage"
            return (200, [
                "forecast_trust": .string(house.safetyK <= 0.25 ? "bold" : house.safetyK < 1.5 ? "balanced" : "cautious"),
                "battery_export": .string(house.batteryExport),
                "safety_k": .number(house.safetyK),
                "mapped_k": .number(house.safetyK),
                "mapped_mode": .string(mapped),
            ])
        case ("GET", "/api/energy/history"):
            let until = min(now, Double(query["until"] ?? "") ?? now)
            let since = Double(query["since"] ?? "") ?? until - 86_400_000
            return (200, ["scope": "system", "since_ms": .number(since), "until_ms": .number(until), "truncated": false, "points": .array(carEnergyRows(sinceMs: since, untilMs: until))])
        case ("GET", "/api/mpc/plan"):
            var plan: JSON = ["actions": .array(mpcActions())]
            if let p = house.carPlan(now) { plan = plan.setting("loadpoint_shortfall_wh", ["garage": .number(p.shortfallWh)]) }
            return (200, ["plan": plan, "meta": ["replanning": false, "outdated": false]])
        case ("POST", "/api/loadpoints/{id}/vehicle"):
            if let wh = body?["capacity_wh"]?.number, wh >= 1_000 { house.carCapacityWh = wh }
            return (200, ["ok": true])
        case ("PUT", "/api/loadpoints/{id}/schedule"):
            // The household clock when sent, else the UTC minute read on
            // today's date: what Core does.
            lastScheduleBody = body
            let today = Date(timeIntervalSince1970: now / 1000)
            let fromUTC = EVText.clockFromUTC(Int(body?["time_of_day_min_utc"]?.number ?? 300), at: today, zone: house.timeZone)
            let clock = readsHouseholdClock ? body?["time_of_day_min"]?.number.map { Int($0) } ?? fromUTC : fromUTC
            house.schedule = (
                body?["soc"]?.number ?? 0.8,
                clock,
                body?["recurring"]?.bool ?? false,
                Int(body?["days"]?.number ?? 0),
                body?["surplus_unlock_bat_soc"]?.number ?? 0
            )
            return (200, ["ok": true])
        case ("DELETE", "/api/loadpoints/{id}/schedule"):
            house.schedule = nil
            return (200, ["ok": true])
        default:
            return (404, [:])
        }
    }

    func loadpointJSON() -> JSON {
        let h = house
        let now = scheduler.nowMs
        // A car that reports counts as the car's word for five minutes, as
        // in Core; after that its report is shown, dated, and FTW estimates.
        var socSource = h.carSocSource
        if let at = h.carReportedAtMs, socSource == "vehicle", now - at > 5 * 60_000 { socSource = "inferred" }
        var lp: JSON = [
            "id": "garage",
            "driver_name": "easee",
            "plugged_in": .bool(h.carPluggedIn),
            "vehicle_capacity_wh": .number(h.carCapacityWh),
            "capacity_source": "user",
            "soc_retention": "session",
            "current_soc": .number(h.carSocFraction),
            "soc_source": .string(h.carPluggedIn ? socSource : ""),
            "current_power_w": .number(h.evWatts),
            "delivered_wh_session": .number(h.sessionWh),
            "min_charge_w": 4_140,
            "max_charge_w": 11_000,
            "phases": 3,
            "voltage_v": 230,
            "manual_active": .bool(h.manualHoldW != nil),
            "manual_charge_w": h.manualHoldW.map { .number($0) } ?? .null,
            "surplus_only": .bool(h.surplusOnly),
            "charger": ["known": true, "available": true, "updated_at_ms": .number(scheduler.nowMs - 2_000)],
            "plan_pending": false,
            "plan_outdated": false,
            "commanded_known": true,
            "commanded_w": .number(h.evWatts),
            "commanded_reason": "",
            "battery_boost": [
                "active": .bool(h.boostUntilMs != nil),
                "expires_at_ms": h.boostUntilMs.map { .number($0) } ?? .null,
                "min_battery_soc": .number(h.boostReserve),
                "stop_reason": .string(h.lastBoostStop ?? ""),
            ],
        ]
        if let at = h.carReportedAtMs, h.carPluggedIn {
            let age = max(0, (now - at) / 1000).rounded()
            lp = lp.setting("vehicle_driver", "demo_car")
            lp = lp.setting("vehicle_soc", .number(h.carSocFraction))
            lp = lp.setting("vehicle_soc_age_s", .number(age))
            lp = lp.setting("vehicle_stale", .bool(age > 15 * 60))
        }
        if let manual = h.manualHoldW {
            let since = h.manualSinceMs ?? now
            let state: String
            if manual == 0 {
                state = "paused"
            } else if h.evWatts > 100 {
                state = "charging"
            } else if !h.holdActing {
                state = now - since < h.chargerRampMs / 2 ? "sent" : "accepted"
            } else {
                state = "not_drawing"
            }
            lp = lp.setting("manual", [
                "active": true,
                "state": .string(state),
                "requested_w": .number(manual),
                "requested_a": .number((manual / 690).rounded()),
                "started_at_ms": .number(since),
            ])
        }
        if let s = h.schedule {
            var schedule: JSON = [
                "soc": .number(s.socFraction),
                // Today's UTC minute of the household clock, as Core answers.
                "time_of_day_min_utc": .number(Double(EVText.minuteUTC(clock: s.clockMin, at: Date(timeIntervalSince1970: now / 1000), zone: h.timeZone))),
                "recurring": .bool(s.recurring), "days": .number(Double(s.days)), "surplus_unlock_bat_soc": .number(s.surplusUnlock),
            ]
            if readsHouseholdClock { schedule = schedule.setting("time_of_day_min", .number(Double(s.clockMin))) }
            lp = lp.setting("schedule", schedule)
            lp = lp.setting("target_soc", .number(s.socFraction))
            if let deadline = h.deadlineMs(now) {
                lp = lp.setting("target_time", .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: deadline / 1000))))
            }
        }
        if let p = h.carPlan(now), p.endMs > p.startMs, p.endMs > now {
            lp = lp.setting("plan_windows", [["start_ms": .number(p.startMs.rounded()), "end_ms": .number(p.endMs.rounded()), "wh": .number(p.wh)]])
            lp = lp.setting("plan_next_start_ms", .number(p.startMs.rounded()))
            lp = lp.setting("plan_next_end_ms", .number(p.endMs.rounded()))
            lp = lp.setting("plan_total_wh", .number(p.wh))
        } else {
            lp = lp.setting("plan_windows", [])
        }
        return lp
    }

    // MARK: Frames out

    private func refuse(_ id: UInt32?, _ code: String, _ args: [(String, CBOR)]) {
        sendBulk(Envelope(t: "error", id: id, b: .map([("code", .text(code)), ("retryable", .bool(Contract.isRetryable(code))), ("args", .map(args))])))
    }

    private func respond(_ id: UInt32?, status: Int, json: JSON) {
        let body = json.encoded()
        sendBulk(Envelope(t: "api.head", id: id, b: .map([("status", .int(status)), ("headers", .map([("content-type", .text("application/json"))])), ("len", .int(body.count))])))
        var seq = 0
        var at = 0
        while at < body.count {
            let end = min(body.count, at + 12_288)
            sendBulk(Envelope(t: "api.chunk", id: id, b: .map([("seq", .int(seq)), ("data", .bytes(Array(body[at..<end])))])))
            seq += 1
            at = end
        }
        sendBulk(Envelope(t: "api.end", id: id, b: .map([("bytes", .int(body.count)), ("truncated", .bool(false))])))
    }

    private func sendBulk(_ env: Envelope) {
        guard let frame = try? Frame.encodeBulk(envelope: env) else { return }
        send?(frame)
    }

    private func sendControl(_ env: Envelope) {
        guard let frame = try? Frame.encode(lane: Frame.laneControl, envelope: env, bucket: subscription?.bucket ?? 512) else { return }
        send?(frame)
    }
}

/// A carrier that reaches a `SimulatedBox` in this process, with latency.
/// Used by the demo; the relay and Noise are not involved, because there is
/// nothing to hide from.
@MainActor
public final class LoopbackCarrier: Carrier {
    public let kind: CarrierKind = .relay
    public private(set) var status: CarrierStatus = .connecting
    private let box: SimulatedBox
    private let scheduler: Scheduler
    private let latencyMs: Double
    private var closed = false
    private var onFrame: @MainActor (Bytes) -> Void = { _ in }
    private var onStatus: @MainActor (CarrierStatus) -> Void = { _ in }
    // Frames in flight, oldest first. A real socket keeps order; timers
    // with the same delay need not fire in order, so each timer delivers
    // the oldest frame rather than its own.
    private var toApp: [Bytes] = []
    private var toBox: [Bytes] = []

    public init(box: SimulatedBox, scheduler: Scheduler, latencyMs: Double = 120) {
        self.box = box
        self.scheduler = scheduler
        self.latencyMs = latencyMs
        box.send = { [weak self] frame in
            guard let self else { return }
            self.toApp.append(frame)
            self.scheduler.after(self.latencyMs) { [weak self] in
                guard let self, !self.closed, !self.toApp.isEmpty else { return }
                self.onFrame(self.toApp.removeFirst())
            }
        }
        scheduler.after(latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.status = .open(sinceMs: scheduler.nowMs)
            self.onStatus(self.status)
        }
    }

    public func setHandlers(onFrame: @escaping @MainActor (Bytes) -> Void, onStatus: @escaping @MainActor (CarrierStatus) -> Void) {
        self.onFrame = onFrame
        self.onStatus = onStatus
    }

    @discardableResult
    public func send(_ frame: Bytes) -> Bool {
        guard status.isOpen, !closed else { return false }
        toBox.append(frame)
        scheduler.after(latencyMs) { [weak self] in
            guard let self, !self.closed, !self.toBox.isEmpty else { return }
            self.box.receive(self.toBox.removeFirst())
        }
        return true
    }

    /// Pull to refresh in the demo: the house moves on a second.
    public func wake() {
        box.tick()
    }

    public func close(reason: String) {
        if closed { return }
        closed = true
        box.stop()
        status = .closed(reason: reason, retryable: false)
    }
}

extension SimulatedBox {
    /// The demo as `AppModel` takes it: a fresh simulated home behind a
    /// loopback carrier, a car just plugged in, and a box and charger that
    /// take a moment to answer, as real ones do.
    public static func loopback(_ scheduler: Scheduler) -> Carrier {
        let box = SimulatedBox(scheduler: scheduler)
        box.resultDelayMs = 900
        box.house.chargerRampMs = 4_000
        #if DEBUG
        // For screenshots: `-FTWDemoCar unplugged` and the like.
        if let name = UserDefaults.standard.string(forKey: "FTWDemoCar"), let car = DemoCar(rawValue: name) {
            car.apply(to: box.house, nowMs: scheduler.nowMs)
        }
        // For recordings: `-FTWDemoGap YES` holds a tile back for 2 s.
        if UserDefaults.standard.bool(forKey: "FTWDemoGap") { box.holdTileMs = 2_000 }
        // For the grid widget: `-FTWDemoSunny YES` makes today a long
        // summer's day that sells more than it buys, and
        // `-FTWDemoPartial YES` leaves a fifth of it unpriced.
        if UserDefaults.standard.bool(forKey: "FTWDemoSunny") { box.house.sunny = true }
        if UserDefaults.standard.bool(forKey: "FTWDemoPartial") { box.pricedShare = 0.8 }
        #endif
        current = box
        return LoopbackCarrier(box: box, scheduler: scheduler)
    }

    /// Plug the demo car in or out.
    public func setCarPluggedIn(_ on: Bool) {
        if on { house.plugIn() } else { house.unplug() }
    }
}

/// The car situations the demo can open in, so each screen of the car view
/// can be shown without a box.
public enum DemoCar: String, CaseIterable, Sendable {
    /// Plugged in, unread: FTW assumes 20 %. The default.
    case assumed
    case unplugged
    /// A level someone gave FTW, charging since.
    case estimated
    /// A car that reports its own level, just now.
    case car
    /// A car that last reported 40 minutes ago.
    case carOld
    /// A goal the night is too short for.
    case late
    /// No goal yet.
    case noGoal
    /// Charge now running.
    case charging

    @MainActor
    public func apply(to h: SimulatedHouse, nowMs: Double) {
        switch self {
        case .assumed: break
        case .unplugged: h.unplug()
        case .estimated:
            h.carSocFraction = 0.46
            h.carSocSource = "inferred"
        case .car:
            h.carReportedAtMs = nowMs - 40_000
            h.carSocFraction = 0.64
            h.carSocSource = "vehicle"
        case .carOld:
            h.carReportedAtMs = nowMs - 40 * 60_000
            h.carSocFraction = 0.58
            h.carSocSource = "vehicle"
        case .late:
            h.carSocFraction = 0.35
            h.carSocSource = "inferred"
            h.schedule = (0.8, 3 * 60, true, 0, 0)
        case .noGoal:
            h.schedule = nil
        case .charging:
            h.carSocFraction = 0.46
            h.carSocSource = "inferred"
            h.manualHoldW = 11_000
        }
    }
}
