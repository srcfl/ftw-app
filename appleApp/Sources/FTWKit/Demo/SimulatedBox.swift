import Foundation

/// A box that lives in this process: the other end of the protocol, for the
/// demo and for the tests. It speaks frames exactly as a box does, holds a
/// `SimulatedHouse`, and answers the same routes and commands the app uses.
///
/// It is not the box and says so: the demo runs behind its own band and
/// writes nothing to disk.
@MainActor
public final class SimulatedBox {
    public let house: SimulatedHouse
    private let scheduler: Scheduler
    private let requireStepUp: Bool
    private let bootedAtMs: Double

    /// Frames to the app.
    public var send: (@MainActor (Bytes) -> Void)?

    private var subscription: Subscription?
    private var telemetry: Cancellable?
    private var seq: UInt64 = 0
    private var controlRev: UInt64 = 1
    private var lastSent: [Int: Double] = [:]
    private var planRev: UInt64 = 1
    public var booting = false
    /// Silence instead of answers, to test the app's deadlines.
    public var mute = false
    /// Ack commands but never report a result.
    public var neverConfirm = false
    public private(set) var receivedCommands: [String] = []
    public private(set) var stepUpsSeen = 0

    // Box-side records the Box screen reads.
    var devices: [(id: String, role: String, addedAtMs: Double, lastSeenMs: Double)] = []
    var notifyEnabled = false
    var notifyRules: [(type: String, enabled: Bool)] = [
        ("charging.connected", false), ("charging.session_complete", false), ("charging.interrupted", false),
        ("update.installed", false), ("driver.offline", false), ("fuse.over_limit", false),
    ]
    var sentPushes: [(title: String, atMs: Double)] = []

    public static let modes: [ModeInfo] = [
        ModeInfo(key: "planner_passive_arbitrage", label: "Passive arbitrage", tooltip: "Charge from the cheapest available source (PV when sunny, grid during cheap hours). Never exports from battery.", tier: "primary"),
        ModeInfo(key: "planner_arbitrage", label: "Active arbitrage", tooltip: "Full price arbitrage — charge cheap, discharge into expensive hours (battery may export to grid).", tier: "primary"),
        ModeInfo(key: "idle", label: "Stop batteries", tooltip: "Hold every battery at 0 W for as long as this mode is on.", tier: "advanced"),
        ModeInfo(key: "self_consumption", label: "Self (manual)", tooltip: "Manual self-consumption — PI chases grid target, no plan.", tier: "advanced"),
        ModeInfo(key: "peak_shaving", label: "Peak", tooltip: "Limit grid import to the configured peak limit.", tier: "advanced"),
        ModeInfo(key: "charge", label: "Charge", tooltip: "Force full charge regardless of price.", tier: "advanced"),
        ModeInfo(key: "planner_self", label: "Planner (self)", tooltip: "Forecast-driven self-consumption.", tier: "hidden"),
    ]

    public init(scheduler: Scheduler, house: SimulatedHouse = SimulatedHouse(), requireStepUp: Bool = false, uptimeAtStartMs: Double = 3_600_000) {
        self.scheduler = scheduler
        self.house = house
        self.requireStepUp = requireStepUp
        bootedAtMs = scheduler.nowMs - uptimeAtStartMs
        house.step(nowMs: scheduler.nowMs, dtMs: 1_000)
        devices = [("Qm94T3du", Contract.roleOwner, scheduler.nowMs - 40 * 86_400_000, scheduler.nowMs - 3 * 3_600_000)]
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

    /// Register a phone, as a pairing on the box would.
    public func enroll(deviceID: String, role: String) {
        devices.insert((deviceID, role, scheduler.nowMs, scheduler.nowMs), at: 0)
    }

    // MARK: Frames in

    public func receive(_ bytes: Bytes) {
        if mute { return }
        guard let frame = try? Frame.decode(bytes) else { return }
        let env = frame.envelope
        let body = env.b ?? CBOR.emptyMap
        switch env.t {
        case "hello": onHello(body)
        case "sub":
            let first = subscription == nil
            subscription = Subscription(bucket: body["bucket"]?.int ?? 512, hz: body["hz"]?.double ?? 1)
            if first { sendSnap() }
            restartTelemetry()
        case "plan.get": sendBulk(Envelope(t: "plan", id: env.id, b: planCBOR()))
        case "price.get": sendBulk(Envelope(t: "price", id: env.id, b: pricesCBOR(from: body["fromMs"]?.double ?? scheduler.nowMs, to: body["toMs"]?.double ?? scheduler.nowMs + 86_400_000)))
        case "hist.query": onHistory(env.id, body)
        case "api.req": onAPI(env.id, body)
        case "cmd": onCommand(body)
        default: break
        }
    }

    private func onHello(_ body: CBOR) {
        let wantsSub = body["sub"]
        var pairs: [(String, CBOR)] = [
            ("proto", .int(Proto.max)),
            ("mode", .text(booting ? "booting" : "full")),
            ("box", .map([("id", .text("demo-box")), ("build", .text("0.131.0-demo")), ("tz", .text(house.timeZone.identifier))])),
            ("clock", .map([("source", .text("ntp")), ("syncedAtMs", .number(scheduler.nowMs - 60_000)), ("uptimeMs", .number(uptimeMs))])),
            ("caps", .array(["status.core", "status.drivers", "history.5m", "history.1h", "history.etag", "cmd.lease", "cmd.readback", "der.battery", "der.ev", "plan.dispatch", "price.spot", "api.passthrough"].map { .text($0) })),
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
            Contract.FID.loadW: house.baseLoadW + house.evWatts,
        ]
        f[Contract.FID.evW] = house.evWatts
        return f
    }

    private func sourcesCBOR() -> CBOR {
        let now = uptimeMs
        func src(_ kind: String, _ name: String) -> CBOR {
            .map([("kind", .text(kind)), ("name", .text(name)), ("lastOkMs", .number(now - 400)), ("staleAfterMs", .int(10_000)), ("state", .text("live"))])
        }
        return .map([("meter", src("meter", "sdm630")), ("inverter", src("inverter", "sungrow")), ("charger", src("charger", "easee"))])
    }

    private func sendSnap() {
        let f = fields
        lastSent = f
        let dict: [(String, CBOR)] = [
            ("1", .map([("name", .text("mode")), ("unit", .null), ("srcId", .null)])),
            ("2", .map([("name", .text("grid_w")), ("unit", .text("W")), ("srcId", .text("meter"))])),
            ("3", .map([("name", .text("pv_w")), ("unit", .text("W")), ("srcId", .text("inverter"))])),
            ("4", .map([("name", .text("battery_w")), ("unit", .text("W")), ("srcId", .text("inverter"))])),
            ("5", .map([("name", .text("battery_soc")), ("unit", .text("permille")), ("srcId", .text("inverter"))])),
            ("6", .map([("name", .text("load_w")), ("unit", .text("W")), ("srcId", .text("meter"))])),
            ("10", .map([("name", .text("ev_w")), ("unit", .text("W")), ("srcId", .text("charger"))])),
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

    // MARK: Plan and prices

    func planSlots() -> [PlanSlot] {
        let slotMs: Double = 900_000
        let start = (scheduler.nowMs / slotMs).rounded(.down) * slotMs
        return (0..<96).map { i in
            let t = start + Double(i) * slotMs
            let price = house.priceAt(t)
            let pv = house.pvAt(t)
            let load = house.baseLoadAt(t)
            var battery = 0.0
            var reason = "idle"
            if -pv > load + 300 {
                battery = min(house.batteryMaxW, -pv - load).rounded(); reason = "solar_surplus"
            } else if price < 45 {
                battery = house.modeKey == "planner_self" ? 0 : 3_000; reason = battery > 0 ? "cheap_import" : "idle"
            } else if price > 110 {
                battery = -min(house.batteryMaxW, load).rounded(); reason = "expensive_import"
            } else if price > 80 {
                reason = "reserve_held"
            }
            return PlanSlot(startMs: t, durationMs: slotMs, batteryW: battery, gridW: load + battery + pv, priceMinor: price, reason: reason)
        }
    }

    func planCBOR() -> CBOR {
        .map([
            ("rev", .unsigned(planRev)),
            ("uptimeMs", .number(uptimeMs)),
            ("slots", .array(planSlots().map { s in
                .map([
                    ("startMs", .number(s.startMs)), ("durationMs", .number(s.durationMs)),
                    ("batteryW", .number(s.batteryW)), ("gridW", .number(s.gridW)),
                    ("priceMinor", s.priceMinor.map { CBOR.number($0) } ?? .null), ("reason", .text(s.reason)),
                ])
            })),
            ("stale", .bool(false)),
            ("ceilingW", .int(11_000)),
        ])
    }

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

    // MARK: History

    private func onHistory(_ id: UInt32?, _ body: CBOR) {
        let series = body["series"]?.stringArray ?? []
        let res = body["res"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        let from = body["fromMs"]?.double ?? scheduler.nowMs - 86_400_000
        let to = body["toMs"]?.double ?? scheduler.nowMs
        let maxPoints = body["maxPoints"]?.int ?? 2000
        var have = [String: String]()
        for h in body["have"]?.array ?? [] {
            if let t = h["tileId"]?.string, let e = h["etag"]?.string { have[t] = e }
        }
        let plan = HistoryGeometry.plan(res, fromMs: from, toMs: to, maxPoints: maxPoints)
        for tile in plan.tiles {
            let partial = tile.startMs + HistoryGeometry.spec(plan.res).tileSpanMs > scheduler.nowMs
            let columns: [[Int32]] = series.map { name in
                (0..<tile.points).map { i in
                    let t = tile.startMs + Double(i) * plan.stepMs
                    if t > scheduler.nowMs { return missingSample }
                    let pv = house.pvAt(t)
                    let load = house.baseLoadAt(t)
                    let battery = max(-5_000, min(5_000, -(load + pv)))
                    switch name {
                    case "pv_w": return Int32(pv)
                    case "load_w": return Int32(load)
                    case "battery_w": return Int32(battery)
                    case "grid_w": return Int32(load + battery + pv)
                    default: return missingSample
                    }
                }
            }
            let data = HistoryGeometry.pack(columns)
            let etag = HistoryGeometry.etag(data)
            if !partial, have[tile.tileId] == etag { continue }
            sendBulk(Envelope(t: "hist.chunk", id: id, b: .map([
                ("tileId", .text(tile.tileId)), ("etag", .text(etag)), ("res", .text(plan.res.rawValue)),
                ("startMs", .number(tile.startMs)), ("stepMs", .number(plan.stepMs)),
                ("series", .array(series.map { .text($0) })), ("data", .bytes(data)), ("partial", .bool(partial)),
            ])))
        }
        sendBulk(Envelope(t: "hist.end", id: id, b: .map([("resActual", .text(plan.res.rawValue)), ("gaps", .array([]))])))
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

        switch op {
        case Contract.opSetMode:
            guard let mode = args["mode"]?.string, Self.modes.contains(where: { $0.key == mode }) else {
                result(cmdId, "rejected", error: ("E_PRECONDITION", []))
                return
            }
            house.modeKey = mode
            controlRev += 1
            planRev += 1
            result(cmdId, "applied", observed: Double(Self.modes.firstIndex { $0.key == mode } ?? 0))
            // A plan pushed unasked after a mode change, as the box does.
            sendBulk(Envelope(t: "plan", b: planCBOR()))
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
        ("GET", "/api/app-link/devices", .read, nil),
        ("POST", "/api/app-link/pairing", .configure, nil),
        ("DELETE", "/api/app-link/devices/{id}", .configure, nil),
        ("GET", "/api/loadpoints", .read, nil),
        ("GET", "/api/mpc/plan", .read, nil),
        ("POST", "/api/loadpoints/{id}/vehicle", .configure, nil),
        ("PUT", "/api/loadpoints/{id}/schedule", .configure, nil),
        ("DELETE", "/api/loadpoints/{id}/schedule", .configure, nil),
        ("POST", "/api/loadpoints/{id}/soc", .actuate, Contract.opLoadpointSocSet),
        ("POST", "/api/mode", .actuate, Contract.opSetMode),
        ("GET", "/api/notifications/vapid", .read, nil),
        ("GET", "/api/notifications/history", .read, nil),
        ("GET", "/api/notifications/rules", .read, nil),
        ("PUT", "/api/notifications/rules", .configure, nil),
        ("POST", "/api/notifications/test", .configure, nil),
        ("POST", "/api/restart", .configure, nil),
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
                "load_w": .number(house.baseLoadW + house.evWatts),
                "energy": ["today": [
                    "import_wh": .number(house.todayImportWh), "export_wh": .number(house.todayExportWh),
                    "pv_wh": .number(house.todayPVWh), "load_wh": .number(house.todayLoadWh),
                    "bat_charged_wh": .number(house.todayChargedWh), "bat_discharged_wh": .number(house.todayDischargedWh),
                ]],
                "drivers": [
                    "sungrow": ["status": "ok", "pv_w": .number(house.pvW), "bat_w": .number(house.batteryW), "bat_soc": .number(house.socFraction)],
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
            let rows: [JSON] = (0..<days).reversed().map { offset in
                ["day": .string(house.localDay(now - Double(offset) * 86_400_000)), "saved_ore": .number((1_400 + 900 * house.wobble(Double(offset) * 1e6, 5)).rounded()), "resolution": "slot"]
            }
            return (200, ["days": .array(rows)])
        case ("GET", "/api/loadpoints"):
            return (200, ["enabled": true, "loadpoints": [loadpointJSON()]])
        case ("GET", "/api/mpc/plan"):
            return (200, ["plan": ["actions": []], "meta": ["replanning": false, "outdated": false]])
        case ("POST", "/api/loadpoints/{id}/vehicle"):
            if let wh = body?["capacity_wh"]?.number, wh >= 1_000 { house.carCapacityWh = wh }
            return (200, ["ok": true])
        case ("PUT", "/api/loadpoints/{id}/schedule"):
            house.schedule = (
                body?["soc"]?.number ?? 0.8,
                Int(body?["time_of_day_min_utc"]?.number ?? 300),
                body?["recurring"]?.bool ?? false,
                Int(body?["days"]?.number ?? 0),
                body?["surplus_unlock_bat_soc"]?.number ?? 0
            )
            return (200, ["ok": true])
        case ("DELETE", "/api/loadpoints/{id}/schedule"):
            house.schedule = nil
            return (200, ["ok": true])
        case ("GET", "/api/app-link/devices"):
            return (200, ["devices": .array(devices.map { ["id": .string($0.id), "role": .string($0.role), "added_at_ms": .number($0.addedAtMs), "last_seen_ms": .number($0.lastSeenMs)] })])
        case ("POST", "/api/app-link/pairing"):
            let role = body?["role"]?.string ?? ""
            guard role == Contract.roleViewer || role == Contract.roleOwner else { return (400, ["code": "E_BAD_ROLE"]) }
            let invite = Enrollment(boxStaticPublic: Bytes(repeating: 7, count: 32), pairingCode: randomBytes(16), lanHint: "", rendezvousSecret: randomBytes(32))
            return (200, ["url": .string(invite.url()), "role": .string(role), "expires_at_ms": .number(now + 600_000)])
        case ("DELETE", "/api/app-link/devices/{id}"):
            guard let itemID, devices.contains(where: { $0.id == itemID }) else { return (404, [:]) }
            let owners = devices.filter { $0.role == Contract.roleOwner }
            if owners.count == 1, owners.first?.id == itemID { return (409, ["code": "E_LAST_OWNER_PROTECTED"]) }
            devices.removeAll { $0.id == itemID }
            return (200, ["ok": true])
        case ("GET", "/api/notifications/vapid"):
            return (200, ["public_key": "BDemoKeyNotForSending"])
        case ("GET", "/api/notifications/history"):
            return (200, ["events": .array(sentPushes.reversed().map { ["title": .string($0.title), "at_ms": .number($0.atMs)] })])
        case ("GET", "/api/notifications/rules"):
            return (200, rulesJSON())
        case ("PUT", "/api/notifications/rules"):
            notifyEnabled = body?["enabled"]?.bool ?? notifyEnabled
            for rule in body?["events"]?.array ?? [] {
                guard let type = rule["type"]?.string, let i = notifyRules.firstIndex(where: { $0.type == type }) else { continue }
                notifyRules[i].enabled = rule["enabled"]?.bool ?? false
            }
            return (200, rulesJSON())
        case ("POST", "/api/notifications/test"):
            sentPushes.append(("Test from your FTW box", now))
            return (200, ["ok": true])
        case ("POST", "/api/restart"):
            return (200, ["status": "restarting"])
        default:
            return (404, [:])
        }
    }

    private func rulesJSON() -> JSON {
        ["enabled": .bool(notifyEnabled), "events": .array(notifyRules.map { ["type": .string($0.type), "enabled": .bool($0.enabled), "threshold": 0] })]
    }

    func loadpointJSON() -> JSON {
        let h = house
        var lp: JSON = [
            "id": "garage",
            "driver_name": "easee",
            "plugged_in": .bool(h.carPluggedIn),
            "vehicle_capacity_wh": .number(h.carCapacityWh),
            "capacity_source": "user",
            "soc_retention": "session",
            "current_soc": .number(h.carSocFraction),
            "soc_source": .string(h.carSocSource),
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
        if let manual = h.manualHoldW {
            lp = lp.setting("manual", [
                "active": true,
                "state": manual == 0 ? "paused" : (h.evWatts > 100 ? "charging" : "sent"),
                "requested_w": .number(manual),
                "requested_a": .number((manual / 690).rounded()),
            ])
        }
        if let s = h.schedule {
            lp = lp.setting("schedule", [
                "soc": .number(s.socFraction), "time_of_day_min_utc": .number(Double(s.minuteUTC)),
                "recurring": .bool(s.recurring), "days": .number(Double(s.days)), "surplus_unlock_bat_soc": .number(s.surplusUnlock),
            ])
            // The next cheap night, as one window.
            let midnight = scheduler.nowMs - h.hourOfDay(scheduler.nowMs) * 3_600_000
            let start = midnight + (h.hourOfDay(scheduler.nowMs) >= 5 ? 25 : 1) * 3_600_000
            let needWh = max(0, (s.socFraction - h.carSocFraction) * h.carCapacityWh)
            lp = lp.setting("plan_windows", needWh > 0 ? [["start_ms": .number(start), "end_ms": .number(start + needWh / 11_000 * 3_600_000), "wh": .number(needWh.rounded())]] : [])
            lp = lp.setting("target_soc", .number(s.socFraction))
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

    public init(box: SimulatedBox, scheduler: Scheduler, latencyMs: Double = 120) {
        self.box = box
        self.scheduler = scheduler
        self.latencyMs = latencyMs
        box.send = { [weak self] frame in
            guard let self else { return }
            self.scheduler.after(self.latencyMs) { [weak self] in
                guard let self, !self.closed else { return }
                self.onFrame(frame)
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

    public func send(_ frame: Bytes) {
        guard status.isOpen, !closed else { return }
        scheduler.after(latencyMs) { [weak self] in
            guard let self, !self.closed else { return }
            self.box.receive(frame)
        }
    }

    public func wake() {}

    public func close(reason: String) {
        if closed { return }
        closed = true
        box.stop()
        status = .closed(reason: reason, retryable: false)
    }
}
