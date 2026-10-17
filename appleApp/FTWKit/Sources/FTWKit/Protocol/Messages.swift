import Foundation
import FTWShared

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

public struct ModeInfo: Equatable, Sendable, Identifiable, Codable {
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

public struct BoxInfo: Equatable, Sendable, Codable {
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
    /// The box's FTW Cloud key, home and names, while the grant is on.
    public var cloud: CloudIdentity?

    init(_ c: CBOR) {
        proto = c["proto"]?.int ?? Proto.max
        cloud = CloudIdentity(c["cloud"])
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

// MARK: - Prices

extension Prices {
    init(_ c: CBOR) {
        self.init(
            zone: c["zone"]?.string ?? "",
            currency: c["currency"]?.string ?? "SEK",
            slots: (c["slots"]?.array ?? []).compactMap { s in
                guard let start = s["startMs"]?.double else { return nil }
                return PriceSlot(
                    startMs: start,
                    durationMs: s["durationMs"]?.double ?? 3_600_000,
                    spotMinor: s["spotMinor"]?.double ?? 0,
                    totalMinor: s["totalMinor"]?.double ?? s["spotMinor"]?.double ?? 0
                )
            },
            stale: c["stale"]?.bool ?? false
        )
    }
}

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
    /// After a car op: the car as the box holds it now, in brief (docs/cars.md,
    /// Ops). Absent from a session whose frames are too small for it.
    public var car: Car?
    /// After `session.car.set`: the charger's car as the box holds it now.
    public var charger: ChargerCar?

    public init(cmdId: String, state: State, observedValue: Double? = nil, errorCode: String? = nil, errorArgs: [String: CBOR] = [:], car: Car? = nil, charger: ChargerCar? = nil) {
        self.cmdId = cmdId
        self.state = state
        self.observedValue = observedValue
        self.errorCode = errorCode
        self.errorArgs = errorArgs
        self.car = car
        self.charger = charger
    }

    init(_ c: CBOR) {
        cmdId = c["cmdId"]?.string ?? ""
        state = c["state"]?.string.flatMap(State.init(rawValue:)) ?? .rejected
        observedValue = c["observed"]?["value"]?.double
        errorCode = c["error"]?["code"]?.string
        errorArgs = c["error"]?["args"]?.textMap ?? [:]
        car = c["car"].flatMap { Car(cbor: $0) }
        charger = c["charger"].flatMap { ChargerCar(cbor: $0) }
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
