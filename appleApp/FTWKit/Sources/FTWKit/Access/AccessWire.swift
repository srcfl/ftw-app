import Foundation

/// The agent messages on the app session (docs/agents.md in srcfl/ftw,
/// Messages), in the shapes `go/protocol/agents.go` gives them. Every
/// request gets `agent.ok` with its id, or an `error` with that id.
public enum AccessWire {
    public static let msgKeySet = Approval.keySet
    public static let msgAdd = Approval.add
    public static let msgWiden = Approval.widen
    public static let msgConfirm = Approval.confirm
    public static let msgRevoke = "agent.revoke"
    public static let msgList = "agent.list"
    public static let msgAudit = "audit.get"
    public static let msgOK = "agent.ok"

    public static let roleAgent = Contract.roleAgent
    public static let roleSupport = Contract.roleSupport
    public static let roleRelease = Contract.roleRelease

    /// The one client a support offer may come from: the support tooling's
    /// client at FTW Cloud.
    public static let supportClientID = "https://cloud.ftw.energy/clients/sourceful-support"

    /// The longest grant each role may have, in ms.
    public static func longestMs(_ role: String) -> Int64 {
        switch role {
        case roleSupport: return 14 * 86_400_000
        case roleRelease: return 90 * 86_400_000
        default: return 365 * 86_400_000
        }
    }

    /// The longest grant a box takes when its `agent.list` names none.
    /// Boxes before `longestMs` took 30 days for an assistant and refuse
    /// more, so the app offers them no more (docs/agents.md in srcfl/ftw,
    /// Mixed versions).
    public static func unstatedLongestMs(_ role: String) -> Int64 {
        switch role {
        case roleSupport, roleRelease: return longestMs(role)
        default: return 30 * 86_400_000
        }
    }

    /// The scopes an owner ticks "control" to add.
    public static let scopeSetup = "ftw.setup.write"
    public static let scopeHold = "ftw.dispatch.hold"
    public static let scopeRequest = "ftw.goals.request"
    public static let controlScopes: Set<String> = [scopeHold, scopeRequest]

    /// The box's own limits on caps.
    public static let holdSRange: ClosedRange<UInt64> = 60...1_800
    public static let maxWRange: ClosedRange<UInt64> = 1...100_000
    public static let perMinDefault: UInt64 = 6
}

public struct Caps: Equatable, Sendable, Codable {
    public var holdS: UInt64
    public var maxW: UInt64
    public var perMin: UInt64

    public init(holdS: UInt64 = 0, maxW: UInt64 = 0, perMin: UInt64 = 0) {
        self.holdS = holdS
        self.maxW = maxW
        self.perMin = perMin
    }

    init(_ c: CBOR?) {
        holdS = c?["holdS"]?.uint ?? 0
        maxW = c?["maxW"]?.uint ?? 0
        perMin = c?["perMin"]?.uint ?? 0
    }

    var cbor: CBOR { .map([("holdS", .unsigned(holdS)), ("maxW", .unsigned(maxW)), ("perMin", .unsigned(perMin))]) }
    /// `[holdS, maxW, perMin]`, as the signature carries them.
    var array: CBOR { .array([.unsigned(holdS), .unsigned(maxW), .unsigned(perMin)]) }
}

public struct Principal: Equatable, Sendable, Codable {
    public var client: String
    public var clientId: String
    public var ticket: String

    public init(client: String = "", clientId: String = "", ticket: String = "") {
        self.client = client
        self.clientId = clientId
        self.ticket = ticket
    }

    init(_ c: CBOR?) {
        client = c?["client"]?.string ?? ""
        clientId = c?["clientId"]?.string ?? ""
        ticket = c?["ticket"]?.string ?? ""
    }

    var cbor: CBOR { .map([("client", .text(client)), ("clientId", .text(clientId)), ("ticket", .text(ticket))]) }
}

/// `agent.add`: an owner grants access.
public struct AgentAdd: Equatable, Sendable {
    public var key: Bytes
    public var role: String
    public var scopes: [String]
    public var ops: [String]
    public var caps: Caps
    public var expiresAtMs: Int64
    public var principal: Principal
    public var atMs: Int64
    public var sig: Bytes = []

    public init(key: Bytes, role: String, scopes: [String], ops: [String], caps: Caps, expiresAtMs: Int64, principal: Principal, atMs: Int64) {
        self.key = key
        self.role = role
        self.scopes = scopes
        self.ops = ops
        self.caps = caps
        self.expiresAtMs = expiresAtMs
        self.principal = principal
        self.atMs = atMs
    }

    public var cbor: CBOR {
        .map([
            ("key", .bytes(key)), ("role", .text(role)),
            ("scopes", .array(scopes.map { .text($0) })), ("ops", .array(ops.map { .text($0) })),
            ("caps", caps.cbor), ("expiresAtMs", .int(expiresAtMs)), ("principal", principal.cbor),
            ("atMs", .int(atMs)), ("sig", .bytes(sig)),
        ]).deterministic
    }
}

/// `agent.widen`: the whole new grant for a row, signed. Any change but a
/// revoke is one, narrowing included.
public struct AgentWiden: Equatable, Sendable {
    public var id: String
    public var epoch: UInt64
    public var scopes: [String]
    public var ops: [String]
    public var caps: Caps
    public var expiresAtMs: Int64
    public var atMs: Int64
    public var sig: Bytes = []

    public init(id: String, epoch: UInt64, scopes: [String], ops: [String], caps: Caps, expiresAtMs: Int64, atMs: Int64) {
        self.id = id
        self.epoch = epoch
        self.scopes = scopes
        self.ops = ops
        self.caps = caps
        self.expiresAtMs = expiresAtMs
        self.atMs = atMs
    }

    public var cbor: CBOR {
        .map([
            ("id", .text(id)), ("epoch", .unsigned(epoch)),
            ("scopes", .array(scopes.map { .text($0) })), ("ops", .array(ops.map { .text($0) })),
            ("caps", caps.cbor), ("expiresAtMs", .int(expiresAtMs)), ("atMs", .int(atMs)), ("sig", .bytes(sig)),
        ]).deterministic
    }
}

/// One agent grant as the box holds it.
public struct AgentRow: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var key: Bytes
    public var role: String
    public var scopes: [String]
    public var ops: [String]
    public var caps: Caps
    public var expiresAtMs: Int64
    public var principal: Principal
    /// `app:<deviceId>` or `lan`.
    public var approvedBy: String
    public var addedAtMs: Int64
    /// 0 when it has never called.
    public var lastSeenMs: Int64
    public var epoch: UInt64

    public init(id: String, key: Bytes, role: String, scopes: [String], ops: [String], caps: Caps, expiresAtMs: Int64,
                principal: Principal, approvedBy: String = "", addedAtMs: Int64 = 0, lastSeenMs: Int64 = 0, epoch: UInt64 = 1) {
        self.id = id
        self.key = key
        self.role = role
        self.scopes = scopes
        self.ops = ops
        self.caps = caps
        self.expiresAtMs = expiresAtMs
        self.principal = principal
        self.approvedBy = approvedBy
        self.addedAtMs = addedAtMs
        self.lastSeenMs = lastSeenMs
        self.epoch = epoch
    }

    init?(_ c: CBOR) {
        guard let id = c["id"]?.string, let key = c["key"]?.byteString else { return nil }
        self.init(
            id: id, key: key, role: c["role"]?.string ?? "", scopes: c["scopes"]?.stringArray ?? [],
            ops: c["ops"]?.stringArray ?? [], caps: Caps(c["caps"]), expiresAtMs: c["expiresAtMs"]?.int64 ?? 0,
            principal: Principal(c["principal"]), approvedBy: c["approvedBy"]?.string ?? "",
            addedAtMs: c["addedAtMs"]?.int64 ?? 0, lastSeenMs: c["lastSeenMs"]?.int64 ?? 0, epoch: c["epoch"]?.uint ?? 0
        )
    }

    public var isSupport: Bool { role == AccessWire.roleSupport }
    /// Holds a charger or asks for a durable change.
    public var hasControl: Bool { !AccessWire.controlScopes.isDisjoint(with: scopes) }
}

/// A durable change an agent asked for, waiting for an owner.
public struct AgentRequest: Equatable, Sendable, Identifiable {
    public var reqId: String
    public var agent: String
    public var op: String
    /// As the box sent them: the hash of exactly these is what approving
    /// signs.
    public var args: CBOR
    /// The agent's own words, never the box's.
    public var why: String
    public var atMs: Int64
    public var expiresAtMs: Int64
    /// pending, approved, declined or expired.
    public var state: String

    public var id: String { reqId }
    public var pending: Bool { state == "pending" }

    public init(reqId: String, agent: String, op: String, args: CBOR, why: String, atMs: Int64, expiresAtMs: Int64, state: String) {
        self.reqId = reqId
        self.agent = agent
        self.op = op
        self.args = args
        self.why = why
        self.atMs = atMs
        self.expiresAtMs = expiresAtMs
        self.state = state
    }

    init?(_ c: CBOR) {
        guard let reqId = c["reqId"]?.string, let agent = c["agent"]?.string, let op = c["op"]?.string else { return nil }
        self.init(reqId: reqId, agent: agent, op: op, args: c["args"] ?? .emptyMap, why: c["why"]?.string ?? "",
                  atMs: c["atMs"]?.int64 ?? 0, expiresAtMs: c["expiresAtMs"]?.int64 ?? 0, state: c["state"]?.string ?? "")
    }
}

/// An owner phone that can approve, by its device id.
public struct ApprovalKeyInfo: Equatable, Sendable {
    public var deviceId: String
    public var setAtMs: Int64

    init?(_ c: CBOR) {
        guard let d = c["deviceId"]?.string else { return nil }
        deviceId = d
        setAtMs = c["setAtMs"]?.int64 ?? 0
    }

    public init(deviceId: String, setAtMs: Int64) {
        self.deviceId = deviceId
        self.setAtMs = setAtMs
    }
}

/// `agent.list` to an owner: every row on the box.
public struct AgentList: Equatable, Sendable {
    public var agents: [AgentRow]
    public var requests: [AgentRequest]
    public var keys: [ApprovalKeyInfo]
    /// The longest grant the box takes for each role, in ms. Empty from a
    /// box before `longestMs`.
    public var longestMs: [String: Int64]

    public init(agents: [AgentRow] = [], requests: [AgentRequest] = [], keys: [ApprovalKeyInfo] = [], longestMs: [String: Int64] = [:]) {
        self.agents = agents
        self.requests = requests
        self.keys = keys
        self.longestMs = longestMs
    }

    init(_ c: CBOR) {
        agents = (c["agents"]?.array ?? []).compactMap(AgentRow.init)
        requests = (c["requests"]?.array ?? []).compactMap(AgentRequest.init)
        keys = (c["keys"]?.array ?? []).compactMap(ApprovalKeyInfo.init)
        var longest: [String: Int64] = [:]
        for e in c["longestMs"]?.entries ?? [] {
            if let role = e.key.string, let ms = e.value.int64, ms > 0 { longest[role] = ms }
        }
        longestMs = longest
    }
}

/// One line of the box's audit log.
public struct AuditRow: Equatable, Sendable, Identifiable {
    public var seq: UInt64
    public var atMs: Int64
    /// `agent:<id>`, `app:<id>`, `lan:<address>` or `box`.
    public var actor: String
    public var role: String
    public var principal: String
    /// Who made a support call, as FTW Cloud named them: `staff:<id>` or
    /// `bot:<name>`. The box cannot check it.
    public var by: String
    public var what: String
    public var target: String
    /// `ok` or an error code.
    public var result: String
    /// Folded reads and refusals: how many of `what` in that minute.
    public var count: UInt64

    public var id: UInt64 { seq }

    public init(seq: UInt64, atMs: Int64, actor: String, role: String = "", principal: String = "", by: String = "",
                what: String, target: String = "", result: String = "ok", count: UInt64 = 0) {
        self.seq = seq
        self.atMs = atMs
        self.actor = actor
        self.role = role
        self.principal = principal
        self.by = by
        self.what = what
        self.target = target
        self.result = result
        self.count = count
    }

    init?(_ c: CBOR) {
        guard let seq = c["seq"]?.uint else { return nil }
        self.init(seq: seq, atMs: c["atMs"]?.int64 ?? 0, actor: c["actor"]?.string ?? "", role: c["role"]?.string ?? "",
                  principal: c["principal"]?.string ?? "", by: c["by"]?.string ?? "", what: c["what"]?.string ?? "",
                  target: c["target"]?.string ?? "", result: c["result"]?.string ?? "", count: c["count"]?.uint ?? 0)
    }
}

public struct AuditPage: Equatable, Sendable {
    public var rows: [AuditRow]
    public var more: Bool

    init(_ c: CBOR) {
        rows = (c["rows"]?.array ?? []).compactMap(AuditRow.init)
        more = c["more"]?.bool ?? false
    }
}

extension CBOR {
    /// A non-negative integer.
    var uint: UInt64? {
        if case .unsigned(let u) = self { return u }
        return nil
    }
}
