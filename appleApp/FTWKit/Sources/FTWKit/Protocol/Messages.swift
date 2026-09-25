import Foundation

/// The message shapes. Names shared with the box come from
/// protocol/registry.yaml, through `Contract`.
///
/// Every decoder here ignores keys it does not know and defaults what an
/// older box leaves out. Every age is measured against the box's uptime,
/// never its wall clock: a Pi has no RTC and reads 1970 until NTP answers.
public enum Proto {
    public static let min = 0
    public static let max = 1
    /// The frozen subset: an app too old for full mode still draws the core.
    public static let floor = 0
}

public enum BoxMode: String, Sendable {
    case full, floor, booting, readonly
}

public enum SourceState: String, Sendable, Codable, Comparable {
    case live, lagging, stale, down, never

    var rank: Int {
        switch self {
        case .live: return 0
        case .lagging: return 1
        case .stale: return 2
        case .down: return 3
        case .never: return 4
        }
    }

    public static func < (a: SourceState, b: SourceState) -> Bool { a.rank < b.rank }
}

public struct Source: Equatable, Sendable, Codable {
    public var kind: String
    public var name: String
    /// Box uptime at the last good reading. Not wall clock.
    public var lastOkMs: Double
    public var staleAfterMs: Double
    public var state: SourceState

    init?(_ c: CBOR) {
        guard c.entries != nil else { return nil }
        kind = c["kind"]?.string ?? ""
        name = c["name"]?.string ?? ""
        lastOkMs = c["lastOkMs"]?.double ?? 0
        staleAfterMs = c["staleAfterMs"]?.double ?? 0
        state = c["state"]?.string.flatMap(SourceState.init(rawValue:)) ?? .never
    }

    public init(kind: String, name: String, lastOkMs: Double, staleAfterMs: Double, state: SourceState) {
        self.kind = kind
        self.name = name
        self.lastOkMs = lastOkMs
        self.staleAfterMs = staleAfterMs
        self.state = state
    }
}

public struct FieldDef: Equatable, Sendable, Codable {
    public var name: String
    public var unit: String?
    /// The source this field's freshness comes from. Nil for fields the box
    /// computes itself, such as the mode.
    public var srcId: String?

    public init(name: String, unit: String?, srcId: String?) {
        self.name = name
        self.unit = unit
        self.srcId = srcId
    }
}

public struct ModeInfo: Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var tooltip: String
    /// Placement, not permission: primary, advanced or hidden.
    public var tier: String
    public var id: String { key }

    public init(key: String, label: String, tooltip: String, tier: String) {
        self.key = key
        self.label = label
        self.tooltip = tooltip
        self.tier = tier
    }
}

public struct BootProgress: Equatable, Sendable {
    public var phase: String
    public var pct: Int
    public var etaMs: Double?
}

public struct BoxInfo: Equatable, Sendable {
    public var id: String
    public var build: String
    public var tz: String
}

public struct HelloOk: Equatable, Sendable {
    public var proto: Int
    public var mode: BoxMode
    public var box: BoxInfo
    public var clockSource: String
    public var syncedAtMs: Double?
    public var uptimeMs: Double
    public var role: String?
    public var scopes: [String]?
    public var caps: [String]
    public var modes: [ModeInfo]
    public var boot: BootProgress?
    public var hint: String?
    public var subscribed: Bool

    init(_ c: CBOR) {
        proto = c["proto"]?.int ?? Proto.max
        mode = c["mode"]?.string.flatMap(BoxMode.init(rawValue:)) ?? .full
        let b = c["box"]
        box = BoxInfo(id: b?["id"]?.string ?? "", build: b?["build"]?.string ?? "", tz: b?["tz"]?.string ?? "")
        let clock = c["clock"]
        clockSource = clock?["source"]?.string ?? "none"
        // Go sends 0 for never synced; 0 is a real 1970 timestamp, so it
        // means nil here.
        let synced = clock?["syncedAtMs"]?.double ?? 0
        syncedAtMs = synced > 0 ? synced : nil
        uptimeMs = clock?["uptimeMs"]?.double ?? 0
        role = c["role"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        scopes = c["scopes"]?.stringArray
        caps = c["caps"]?.stringArray ?? []
        modes = (c["modes"]?.array ?? []).compactMap { m in
            guard let key = m["key"]?.string else { return nil }
            return ModeInfo(key: key, label: m["label"]?.string ?? key, tooltip: m["tooltip"]?.string ?? "", tier: m["tier"]?.string ?? "advanced")
        }
        if let boot = c["boot"], boot.entries != nil {
            self.boot = BootProgress(phase: boot["phase"]?.string ?? "", pct: boot["pct"]?.int ?? 0, etaMs: boot["etaMs"]?.double)
        }
        hint = c["hint"]?.string
        subscribed = c["subscribed"]?.bool ?? false
    }
}

/// Fields arrive as a text-keyed map of integers: `{"2": -3000}`.
func decodeFields(_ c: CBOR?) -> [Int: Double] {
    var out = [Int: Double]()
    for e in c?.entries ?? [] {
        let key: Int?
        switch e.key {
        case .text(let s): key = Int(s)
        default: key = e.key.int
        }
        if let key, let v = e.value.double { out[key] = v }
    }
    return out
}

func decodeSources(_ c: CBOR?) -> [String: Source] {
    var out = [String: Source]()
    for e in c?.entries ?? [] {
        if let k = e.key.string, let s = Source(e.value) { out[k] = s }
    }
    return out
}

func decodeDict(_ c: CBOR?) -> [Int: FieldDef] {
    var out = [Int: FieldDef]()
    for e in c?.entries ?? [] {
        guard let k = e.key.string.flatMap(Int.init) ?? e.key.int else { continue }
        out[k] = FieldDef(
            name: e.value["name"]?.string ?? "",
            unit: e.value["unit"]?.string,
            srcId: e.value["srcId"]?.string
        )
    }
    return out
}

public struct Snap: Sendable {
    public var uptimeMs: Double
    public var controlRev: UInt64
    public var dict: [Int: FieldDef]
    public var fields: [Int: Double]
    public var sources: [String: Source]
    public var dispatchBlockedBy: [String]

    init(_ c: CBOR) {
        uptimeMs = c["uptimeMs"]?.double ?? 0
        controlRev = UInt64(max(0, c["controlRev"]?.int64 ?? 0))
        dict = decodeDict(c["dict"])
        fields = decodeFields(c["fields"])
        sources = decodeSources(c["sources"])
        dispatchBlockedBy = c["dispatchBlockedBy"]?.stringArray ?? []
    }
}

public struct Delta: Sendable {
    public var seq: UInt64
    public var uptimeMs: Double
    public var fields: [Int: Double]
    public var sources: [String: Source]?
    public var dispatchBlockedBy: [String]?

    init(_ c: CBOR) {
        seq = UInt64(max(0, c["seq"]?.int64 ?? 0))
        uptimeMs = c["uptimeMs"]?.double ?? 0
        fields = decodeFields(c["fields"])
        sources = c["sources"].map { decodeSources($0) }
        dispatchBlockedBy = c["dispatchBlockedBy"]?.stringArray
    }
}

// MARK: - Plan and prices

public struct PlanSlot: Equatable, Sendable, Identifiable {
    /// Wall clock: these are future times a person reads.
    public var startMs: Double
    public var durationMs: Double
    /// Signed watts at the battery, site convention: positive charges.
    public var batteryW: Double
    /// Expected import at the meter; negative means expected export.
    public var gridW: Double
    /// Import price in minor units per kWh, nil when unknown.
    public var priceMinor: Double?
    /// A stable code, never prose. The app owns every word.
    public var reason: String
    public var id: Double { startMs }

    public init(startMs: Double, durationMs: Double, batteryW: Double, gridW: Double, priceMinor: Double?, reason: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.batteryW = batteryW
        self.gridW = gridW
        self.priceMinor = priceMinor
        self.reason = reason
    }
}

public struct Plan: Equatable, Sendable {
    public var rev: UInt64
    public var uptimeMs: Double
    public var slots: [PlanSlot]
    /// The planner could not run and the box fell back. "Nothing scheduled"
    /// and "we do not know what is scheduled" are different sentences.
    public var stale: Bool
    public var ceilingW: Double?

    public init(rev: UInt64, uptimeMs: Double, slots: [PlanSlot], stale: Bool, ceilingW: Double?) {
        self.rev = rev
        self.uptimeMs = uptimeMs
        self.slots = slots
        self.stale = stale
        self.ceilingW = ceilingW
    }

    init(_ c: CBOR) {
        rev = UInt64(max(0, c["rev"]?.int64 ?? 0))
        uptimeMs = c["uptimeMs"]?.double ?? 0
        slots = (c["slots"]?.array ?? []).compactMap { s in
            guard let start = s["startMs"]?.double else { return nil }
            return PlanSlot(
                startMs: start,
                durationMs: s["durationMs"]?.double ?? 900_000,
                batteryW: s["batteryW"]?.double ?? 0,
                gridW: s["gridW"]?.double ?? 0,
                priceMinor: s["priceMinor"]?.double,
                reason: s["reason"]?.string ?? "idle"
            )
        }
        stale = c["stale"]?.bool ?? false
        ceilingW = c["ceilingW"]?.double
    }
}

public struct PriceSlot: Equatable, Sendable, Identifiable {
    public var startMs: Double
    public var durationMs: Double
    /// Integer minor units per kWh. Money never crosses as a float.
    public var spotMinor: Double
    /// What the household pays, tariff and tax included, computed by the box.
    public var totalMinor: Double
    public var id: Double { startMs }

    public init(startMs: Double, durationMs: Double, spotMinor: Double, totalMinor: Double) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.spotMinor = spotMinor
        self.totalMinor = totalMinor
    }
}

public struct Prices: Equatable, Sendable {
    public var zone: String
    public var currency: String
    public var slots: [PriceSlot]
    /// The answer does not cover the window asked for. Which of the three
    /// shapes it is has to be read off the slots.
    public var stale: Bool

    public init(zone: String, currency: String, slots: [PriceSlot], stale: Bool) {
        self.zone = zone
        self.currency = currency
        self.slots = slots
        self.stale = stale
    }

    init(_ c: CBOR) {
        zone = c["zone"]?.string ?? ""
        currency = c["currency"]?.string ?? "SEK"
        slots = (c["slots"]?.array ?? []).compactMap { s in
            guard let start = s["startMs"]?.double else { return nil }
            return PriceSlot(
                startMs: start,
                durationMs: s["durationMs"]?.double ?? 3_600_000,
                spotMinor: s["spotMinor"]?.double ?? 0,
                totalMinor: s["totalMinor"]?.double ?? s["spotMinor"]?.double ?? 0
            )
        }
        stale = c["stale"]?.bool ?? false
    }
}

// MARK: - History

public enum Resolution: String, Sendable, CaseIterable {
    case fiveMinutes = "5m"
    case hour = "1h"
}

public struct HistQuery: Sendable {
    public var series: [String]
    public var res: Resolution
    public var fromMs: Double
    public var toMs: Double
    public var have: [(tileId: String, etag: String)]
    public var maxPoints: Int?

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("series", .array(series.map { .text($0) })),
            ("res", .text(res.rawValue)),
            // Whole milliseconds: the box reads these into int64 and drops a
            // query whose times carry a fraction.
            ("fromMs", .ms(fromMs)),
            ("toMs", .ms(toMs)),
        ]
        if !have.isEmpty {
            pairs.append(("have", .array(have.map { .map([("tileId", .text($0.tileId)), ("etag", .text($0.etag))]) })))
        }
        if let maxPoints { pairs.append(("maxPoints", .int(maxPoints))) }
        return .map(pairs)
    }
}

public struct HistChunk: Sendable {
    public var tileId: String
    public var etag: String
    public var res: Resolution
    public var startMs: Double
    public var stepMs: Double
    public var series: [String]
    /// Column-packed int32 little-endian, one block per series.
    public var data: Bytes
    /// The trailing tile is still filling; never cache it.
    public var partial: Bool

    init?(_ c: CBOR) {
        guard let tileId = c["tileId"]?.string else { return nil }
        self.tileId = tileId
        etag = c["etag"]?.string ?? ""
        res = c["res"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        startMs = c["startMs"]?.double ?? 0
        stepMs = c["stepMs"]?.double ?? 300_000
        series = c["series"]?.stringArray ?? []
        data = c["data"]?.byteString ?? []
        partial = c["partial"]?.bool ?? false
    }

    public init(tileId: String, etag: String, res: Resolution, startMs: Double, stepMs: Double, series: [String], data: Bytes, partial: Bool) {
        self.tileId = tileId
        self.etag = etag
        self.res = res
        self.startMs = startMs
        self.stepMs = stepMs
        self.series = series
        self.data = data
        self.partial = partial
    }
}

public struct HistGap: Equatable, Sendable {
    public var fromMs: Double
    public var toMs: Double
    public var reason: String
}

public struct HistEnd: Sendable {
    /// What the box actually served, which may be coarser than asked for.
    public var resActual: Resolution
    public var gaps: [HistGap]

    init(_ c: CBOR) {
        resActual = c["resActual"]?.string.flatMap(Resolution.init(rawValue:)) ?? .fiveMinutes
        gaps = (c["gaps"]?.array ?? []).compactMap { g in
            guard let from = g["fromMs"]?.double, let to = g["toMs"]?.double else { return nil }
            return HistGap(fromMs: from, toMs: to, reason: g["reason"]?.string ?? "no_data")
        }
    }
}

/// Distinct from zero, which is a real reading.
public let missingSample = Int32.min

// MARK: - The box's own API

public enum APIMethod: String, Sendable {
    case get = "GET", head = "HEAD", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

/// A request against the box's own HTTP API, carried in the session.
///
/// There is no headers field, deliberately: the caller's identity rides on
/// the request context inside the box, put there by the session that
/// authenticated it, so no byte this app sends becomes a claim about who is
/// asking. The query is parsed, never a raw string.
public struct APIRequest: Sendable {
    public var method: APIMethod
    public var path: String
    public var query: [String: String]
    public var body: Bytes?
    public var stepUp: Bool

    public init(method: APIMethod, path: String, query: [String: String] = [:], body: Bytes? = nil, stepUp: Bool = false) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.stepUp = stepUp
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [
            ("maxBytes", .int(Session.apiMaxBytes)),
            ("method", .text(method.rawValue)),
            ("path", .text(path)),
        ]
        if !query.isEmpty {
            pairs.append(("query", .map(query.sorted { $0.key < $1.key }.map { ($0.key, CBOR.text($0.value)) })))
        }
        if let body { pairs.append(("body", .bytes(body))) }
        if stepUp { pairs.append(("stepUp", .bool(true))) }
        return .map(pairs)
    }
}

public struct APIResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Bytes
}

// MARK: - Commands

public struct Guard: Sendable {
    public var fid: Int
    public var op: String
    public var value: Double

    public init(fid: Int, op: String, value: Double) {
        self.fid = fid
        self.op = op
        self.value = value
    }
}

public struct CmdResult: Equatable, Sendable {
    public enum State: String, Sendable {
        case applied, rejected, expired, superseded, unconfirmed
    }

    public var cmdId: String
    public var state: State
    /// Present when the driver read the value back. The real proof.
    public var observedValue: Double?
    public var errorCode: String?
    public var errorArgs: [String: CBOR]

    public init(cmdId: String, state: State, observedValue: Double? = nil, errorCode: String? = nil, errorArgs: [String: CBOR] = [:]) {
        self.cmdId = cmdId
        self.state = state
        self.observedValue = observedValue
        self.errorCode = errorCode
        self.errorArgs = errorArgs
    }

    init(_ c: CBOR) {
        cmdId = c["cmdId"]?.string ?? ""
        state = c["state"]?.string.flatMap(State.init(rawValue:)) ?? .rejected
        observedValue = c["observed"]?["value"]?.double
        errorCode = c["error"]?["code"]?.string
        errorArgs = c["error"]?["args"]?.textMap ?? [:]
    }
}

// MARK: - Errors and teardown

public struct ErrorMsg: Equatable, Sendable {
    public var code: String
    public var retryable: Bool
    public var retryAfterMs: Double?
    public var args: [String: CBOR]

    public init(code: String, retryable: Bool? = nil, args: [String: CBOR] = [:]) {
        self.code = code
        self.retryable = retryable ?? Contract.isRetryable(code)
        self.args = args
    }

    init(_ c: CBOR) {
        code = c["code"]?.string ?? "E_UNKNOWN"
        retryable = c["retryable"]?.bool ?? Contract.isRetryable(code)
        retryAfterMs = c["retryAfterMs"]?.double
        args = c["args"]?.textMap ?? [:]
    }
}

public enum TerminateReason: String, Sendable {
    case revoked, epochChanged = "epoch_changed", boxShutdown = "box_shutdown", superseded
}
