import Foundation
import FTWKit

/// The simulated box's agents (docs/agents.md in srcfl/ftw): an assistant,
/// a support grant for one ticket, a request waiting for the owner, and the
/// audit log behind them. It checks each approval signature as the box
/// does, over the bytes the box would build, with the key the phone
/// registered.
///
/// It is not the box: it keeps nothing, runs no op and lets no one in. Its
/// offers are signed with a key made in this process, which only the demo
/// pins, so a demo offer reaches the simulated box and nothing else.
@MainActor
public final class SimulatedAccess {
    public private(set) var rows: [AgentRow] = []
    public private(set) var requests: [AgentRequest] = []
    /// deviceId → registered approval key.
    public private(set) var keys: [String: Bytes] = [:]
    public private(set) var audit: [AuditRow] = []
    /// The longest grant this box takes for each role, as its `agent.list`
    /// says. Nil is a box from before `longestMs`: it says nothing and takes
    /// 30 days for an assistant.
    public var longestMs: [String: Int64]? = Dictionary(uniqueKeysWithValues:
        [Contract.roleAgent, Contract.roleSupport, Contract.roleRelease].map { ($0, AccessWire.longestMs($0)) })
    private var seen = Set<Bytes>()
    private var seq: UInt64 = 0
    let nowMs: @MainActor () -> Double
    let signedFor = AccessModel.demoFor

    init(nowMs: @escaping @MainActor () -> Double) {
        self.nowMs = nowMs
    }

    func longest(_ role: String) -> Int64 {
        longestMs?[role] ?? AccessWire.unstatedLongestMs(role)
    }

    /// A lived-in home: Claude for a week, Sourceful on a ticket, and Claude
    /// asking for a change of mode.
    public func seed() {
        let now = Int64(nowMs())
        let day: Int64 = 86_400_000
        rows = [
            AgentRow(id: "q7Xn2vKd", key: Bytes(repeating: 0x11, count: 32), role: Contract.roleAgent,
                     scopes: ["ftw.goals.request", "ftw.health.read", "ftw.live.read", "ftw.plan.read"], ops: ["site.mode.set"],
                     caps: Caps(perMin: 6), expiresAtMs: now + 23 * day, principal: Principal(client: "Claude", clientId: "https://claude.ai/oauth/mcp-oauth-client-metadata"),
                     approvedBy: "app:\(signedFor.deviceID)", addedAtMs: now - 7 * day, lastSeenMs: now - 12 * 60_000, epoch: 1),
            AgentRow(id: "Hs93LmQa", key: Bytes(repeating: 0x22, count: 32), role: Contract.roleSupport,
                     scopes: ["ftw.config.read", "ftw.diag.run", "ftw.health.read", "ftw.live.read", "ftw.logs.read"], ops: [],
                     caps: Caps(perMin: 6), expiresAtMs: now + 5 * day, principal: Principal(client: "Sourceful support", clientId: AccessWire.supportClientID, ticket: "FTW-1042"),
                     approvedBy: "app:\(signedFor.deviceID)", addedAtMs: now - 2 * day, lastSeenMs: now - 3 * 3_600_000, epoch: 1),
        ]
        requests = [
            AgentRequest(reqId: "AAECAwQFBgcICQoLDA0ODw", agent: "q7Xn2vKd", op: "site.mode.set",
                         args: .map([("mode", .text("self_consumption"))]),
                         why: "Tomorrow looks sunny and tonight's prices are flat, so the battery can wait for the sun.",
                         atMs: now - 4 * 60_000, expiresAtMs: now - 4 * 60_000 + 12 * 3_600_000, state: "pending"),
        ]
        // Oldest first, so the newest row has the highest seq.
        let past: [(String, String, String, UInt64)] = [
            ("app:\(signedFor.deviceID)", "", "agent.add", 0),
            ("agent:q7Xn2vKd", "", "live.get", 12), ("agent:q7Xn2vKd", "", "plan.get", 4), ("agent:q7Xn2vKd", "", "agent.request", 0),
            ("agent:Hs93LmQa", "staff:anna.lindqvist", "health.get", 1), ("agent:Hs93LmQa", "staff:anna.lindqvist", "logs.get", 3),
        ]
        for (i, row) in past.enumerated() {
            log(row.0, by: row.1, what: row.2, result: "ok", count: row.3, atMs: now - Int64(past.count - i) * 9 * 60_000)
        }
    }

    // MARK: Messages

    /// For a test: act on the next message but lose its answer, as a
    /// dropped connection would.
    public var loseNextAnswer = false

    func receive(_ env: Envelope, reply given: @escaping (Envelope) -> Void) {
        var reply = given
        if loseNextAnswer {
            loseNextAnswer = false
            reply = { _ in }
        }
        let body = env.b ?? .emptyMap
        let ok = { (b: CBOR) in reply(Envelope(t: AccessWire.msgOK, id: env.id, b: b)) }
        let refuse = { (code: String, args: [(String, CBOR)]) in
            reply(Envelope(t: "error", id: env.id, b: .map([("code", .text(code)), ("retryable", .bool(Contract.isRetryable(code))), ("args", .map(args))])))
        }
        let now = Int64(nowMs())
        switch env.t {
        case AccessWire.msgList:
            var list: [(String, CBOR)] = [
                ("agents", .array(rows.map(Self.cbor))),
                ("requests", .array(requests.map(Self.cbor))),
                ("keys", .array(keys.keys.sorted().map { .map([("deviceId", .text($0)), ("setAtMs", .int(now))]) })),
            ]
            if let longestMs {
                list.append(("longestMs", .map(longestMs.keys.sorted().map { CBOR.Entry(.text($0), .int(longestMs[$0] ?? 0)) })))
            }
            ok(.map(list))
        case AccessWire.msgAudit:
            let before = body["beforeSeq"]?.int64.map(UInt64.init) ?? .max
            let n = min(body["n"]?.int ?? 200, 200)
            let page = audit.filter { $0.seq < before }.prefix(n)
            ok(.map([("rows", .array(page.map(Self.cbor))), ("more", .bool(audit.filter { $0.seq < before }.count > n))]))
        case AccessWire.msgKeySet:
            guard let pub = body["pub"]?.byteString, let atMs = body["atMs"]?.int64, let sig = body["sig"]?.byteString else { return refuse("E_UNKNOWN_OP", [("field", .text("body"))]) }
            let msg = Approval.keySetBytes(signedFor, atMs: atMs, pub: pub)
            if let old = keys[signedFor.deviceID], !old.isEmpty {
                guard let prev = body["prevSig"]?.byteString, Approval.verify(pub: old, message: msg, sig: prev) else {
                    return refuse("E_BAD_SIGNATURE", [("field", .text("prevSig"))])
                }
            }
            if let code = check(pub, msg, sig, atMs: atMs, now: now) { return refuse(code.0, code.1) }
            keys[signedFor.deviceID] = pub
            log("app:\(signedFor.deviceID)", what: AccessWire.msgKeySet, target: signedFor.deviceID, result: "ok")
            ok(.map([("deviceId", .text(signedFor.deviceID)), ("setAtMs", .int(now))]))
        case AccessWire.msgAdd:
            guard let pub = keys[signedFor.deviceID], !pub.isEmpty else { return refuse("E_NO_APPROVAL_KEY", []) }
            guard let key = body["key"]?.byteString, key.count == 32, let atMs = body["atMs"]?.int64, let sig = body["sig"]?.byteString else {
                return refuse("E_UNKNOWN_OP", [("field", .text("body"))])
            }
            var add = AgentAdd(key: key, role: body["role"]?.string ?? "", scopes: body["scopes"]?.stringArray ?? [], ops: body["ops"]?.stringArray ?? [],
                               caps: Caps(holdS: UInt64(body["caps"]?["holdS"]?.int ?? 0), maxW: UInt64(body["caps"]?["maxW"]?.int ?? 0), perMin: UInt64(body["caps"]?["perMin"]?.int ?? 0)),
                               expiresAtMs: body["expiresAtMs"]?.int64 ?? 0,
                               principal: Principal(client: body["principal"]?["client"]?.string ?? "", clientId: body["principal"]?["clientId"]?.string ?? "", ticket: body["principal"]?["ticket"]?.string ?? ""),
                               atMs: atMs)
            add.sig = sig
            guard let msg = try? Approval.addBytes(signedFor, add) else { return refuse("E_UNKNOWN_OP", [("field", .text("order"))]) }
            if let code = check(pub, msg, sig, atMs: atMs, now: now) { return refuse(code.0, code.1) }
            guard add.expiresAtMs > now, add.expiresAtMs <= now + longest(add.role) else {
                return refuse("E_CAP_EXCEEDED", [("cap", .text("expiresAtMs")), ("max", .int(now + longest(add.role)))])
            }
            let id = String(Base64url.encode(key).prefix(8))
            guard !rows.contains(where: { $0.id == id }) else { return refuse("E_UNKNOWN_OP", [("field", .text("key"))]) }
            var caps = add.caps
            if caps.perMin == 0 { caps.perMin = AccessWire.perMinDefault }
            let row = AgentRow(id: id, key: key, role: add.role, scopes: add.scopes, ops: add.ops, caps: caps, expiresAtMs: add.expiresAtMs,
                               principal: add.principal, approvedBy: "app:\(signedFor.deviceID)", addedAtMs: now, lastSeenMs: 0, epoch: 1)
            rows.append(row)
            rows.sort { $0.id < $1.id }
            log("app:\(signedFor.deviceID)", what: AccessWire.msgAdd, target: id, result: "ok")
            ok(.map([("agent", Self.cbor(row))]))
        case AccessWire.msgWiden:
            guard let pub = keys[signedFor.deviceID], !pub.isEmpty else { return refuse("E_NO_APPROVAL_KEY", []) }
            guard let id = body["id"]?.string, let i = rows.firstIndex(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", []) }
            guard let epoch = body["epoch"]?.int64, UInt64(epoch) == rows[i].epoch else {
                return refuse("E_CONFLICT", [("expected", body["epoch"] ?? .null), ("actual", .unsigned(rows[i].epoch))])
            }
            guard let atMs = body["atMs"]?.int64, let sig = body["sig"]?.byteString else { return refuse("E_UNKNOWN_OP", [("field", .text("body"))]) }
            let m = AgentWiden(id: id, epoch: UInt64(epoch), scopes: body["scopes"]?.stringArray ?? [], ops: body["ops"]?.stringArray ?? [],
                               caps: Caps(holdS: UInt64(body["caps"]?["holdS"]?.int ?? 0), maxW: UInt64(body["caps"]?["maxW"]?.int ?? 0), perMin: UInt64(body["caps"]?["perMin"]?.int ?? 0)),
                               expiresAtMs: body["expiresAtMs"]?.int64 ?? 0, atMs: atMs)
            guard let msg = try? Approval.widenBytes(signedFor, m, key: rows[i].key) else { return refuse("E_UNKNOWN_OP", [("field", .text("order"))]) }
            if let code = check(pub, msg, sig, atMs: atMs, now: now) { return refuse(code.0, code.1) }
            guard m.expiresAtMs > now, m.expiresAtMs <= now + longest(rows[i].role) else {
                return refuse("E_CAP_EXCEEDED", [("cap", .text("expiresAtMs")), ("max", .int(now + longest(rows[i].role)))])
            }
            rows[i].scopes = m.scopes
            rows[i].ops = m.ops
            rows[i].caps = m.caps
            rows[i].expiresAtMs = m.expiresAtMs
            rows[i].epoch += 1
            log("app:\(signedFor.deviceID)", what: AccessWire.msgWiden, target: id, result: "ok")
            ok(.map([("agent", Self.cbor(rows[i]))]))
        case AccessWire.msgRevoke:
            guard let id = body["id"]?.string, rows.contains(where: { $0.id == id }) else { return refuse("E_NOT_FOUND", []) }
            rows.removeAll { $0.id == id }
            requests.removeAll { $0.agent == id }
            log("app:\(signedFor.deviceID)", what: AccessWire.msgRevoke, target: id, result: "ok")
            ok(.map([("id", .text(id))]))
        case AccessWire.msgConfirm:
            guard let reqId = body["reqId"]?.string, let i = requests.firstIndex(where: { $0.reqId == reqId && $0.pending }) else { return refuse("E_NOT_FOUND", []) }
            guard body["approve"]?.bool == true else {
                requests[i].state = "declined"
                log("app:\(signedFor.deviceID)", what: AccessWire.msgConfirm, target: reqId, result: "declined")
                return ok(.map([("reqId", .text(reqId)), ("state", .text("declined"))]))
            }
            guard let pub = keys[signedFor.deviceID], !pub.isEmpty else { return refuse("E_NO_APPROVAL_KEY", []) }
            guard let atMs = body["atMs"]?.int64, let sig = body["sig"]?.byteString else { return refuse("E_UNKNOWN_OP", [("field", .text("body"))]) }
            let msg = Approval.confirmBytes(signedFor, reqId: reqId, atMs: atMs, request: requests[i])
            if let code = check(pub, msg, sig, atMs: atMs, now: now) { return refuse(code.0, code.1) }
            requests[i].state = "approved"
            log("app:\(signedFor.deviceID)", what: AccessWire.msgConfirm, target: reqId, result: "approved")
            ok(.map([("reqId", .text(reqId)), ("state", .text("approved")), ("cmdId", .text("req:\(reqId)"))]))
        default:
            refuse("E_UNKNOWN_OP", [("t", .text(env.t))])
        }
    }

    /// The box's checks on a signature: fresh, never seen, and over these
    /// bytes.
    private func check(_ pub: Bytes, _ msg: Bytes, _ sig: Bytes, atMs: Int64, now: Int64) -> (String, [(String, CBOR)])? {
        guard abs(atMs - now) <= Approval.skewMs else { return ("E_CLOCK_SKEW", [("boxMs", .int(now))]) }
        guard Approval.verify(pub: pub, message: msg, sig: sig) else { return ("E_BAD_SIGNATURE", []) }
        let digest = Primitives.sha256(msg)
        guard seen.insert(digest).inserted else { return ("E_BAD_SIGNATURE", [("field", .text("replay"))]) }
        return nil
    }

    private func log(_ actor: String, by: String = "", what: String, target: String = "", result: String, count: UInt64 = 0, atMs: Int64? = nil) {
        seq += 1
        let role = actor.hasPrefix("agent:") ? (rows.first { "agent:\($0.id)" == actor }?.role ?? "") : Contract.roleOwner
        audit.insert(AuditRow(seq: seq, atMs: atMs ?? Int64(nowMs()), actor: actor, role: role, by: by, what: what, target: target, result: result, count: count), at: 0)
    }

    // MARK: Offers

    /// The demo's own offer key, made in this process.
    public static let offerKey = SoftwareSigner()

    /// `kid:pub` for the demo's offer key, for the demo's `OfferKeys`.
    public static var offerKeys: OfferKeys {
        OfferKeys(pins: ["\(OfferKeys.kid(offerKey.publicKey)):\(Base64url.encode(offerKey.publicKey))"])
    }

    /// An offer as FTW Cloud's consent page makes one, signed by the demo's
    /// key: Claude, asking to read and to control, or Sourceful support for
    /// one ticket.
    public static func offer(support: Bool = false, ticket: String = "FTW-1043", code: String = "K7QF2MXD", nowMs: Double) -> SignedOffer {
        var o = GrantOffer()
        o.v = GrantOffer.version
        o.key = randomBytes(32)
        if support {
            o.role = Contract.roleSupport
            o.client = "Sourceful support"
            o.clientId = AccessWire.supportClientID
            o.clientHost = "cloud.ftw.energy"
            o.verified = true
            o.scopes = ["ftw.config.read", "ftw.diag.run", "ftw.dispatch.hold", "ftw.events.read", "ftw.goals.request", "ftw.health.read", "ftw.history.read", "ftw.live.read", "ftw.logs.read", "ftw.plan.read"]
            o.ticket = ticket
            o.ttlS = UInt64(AccessWire.longestMs(Contract.roleSupport) / 1000)
        } else {
            o.role = Contract.roleAgent
            o.client = "Claude"
            o.clientId = "https://claude.ai/oauth/mcp-oauth-client-metadata"
            o.clientHost = "claude.ai"
            o.verified = true
            o.scopes = ["ftw.dispatch.hold", "ftw.events.read", "ftw.goals.request", "ftw.health.read", "ftw.history.read", "ftw.live.read", "ftw.plan.read"]
            o.ttlS = UInt64(AccessWire.longestMs(Contract.roleAgent) / 1000)
        }
        o.ops = ["car.goal.set", "loadpoint.hold", "planner.prefs.set", "site.mode.set"]
        o.caps = Caps(holdS: 1_800, maxW: 11_000, perMin: 6)
        o.code = code
        o.expMs = Int64(nowMs) + 9 * 60_000
        let raw = encodeDeterministic(o.cbor)
        return SignedOffer(o: raw, kid: OfferKeys.kid(offerKey.publicKey), sig: (try? offerKey.sign(SignedOffer.signedBytes(raw))) ?? [])
    }

    /// The simulated consent page's code lookup: the demo's code finds a
    /// fresh offer, any other none.
    public static let lookup = OfferLookup(base: URL(string: "https://demo.invalid")!) { req in
        let code = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        guard code == "K7QF2MXD" else { return (Data(), 404) }
        let signed: String = await MainActor.run { () -> String in
            SimulatedAccess.offer(nowMs: Date().timeIntervalSince1970 * 1000).base64url
        }
        return (try JSONSerialization.data(withJSONObject: ["offer": signed, "status": "pending"]), 200)
    }

    // MARK: Encoding, as the box encodes

    static func cbor(_ r: AgentRow) -> CBOR {
        .map([
            ("id", .text(r.id)), ("key", .bytes(r.key)), ("role", .text(r.role)),
            ("scopes", .array(r.scopes.map { .text($0) })), ("ops", .array(r.ops.map { .text($0) })),
            ("caps", .map([("holdS", .unsigned(r.caps.holdS)), ("maxW", .unsigned(r.caps.maxW)), ("perMin", .unsigned(r.caps.perMin))])),
            ("expiresAtMs", .int(r.expiresAtMs)),
            ("principal", .map([("client", .text(r.principal.client)), ("clientId", .text(r.principal.clientId)), ("ticket", .text(r.principal.ticket))])),
            ("approvedBy", .text(r.approvedBy)), ("addedAtMs", .int(r.addedAtMs)), ("lastSeenMs", .int(r.lastSeenMs)), ("epoch", .unsigned(r.epoch)),
        ])
    }

    static func cbor(_ r: AgentRequest) -> CBOR {
        .map([
            ("reqId", .text(r.reqId)), ("agent", .text(r.agent)), ("op", .text(r.op)), ("args", r.args), ("why", .text(r.why)),
            ("atMs", .int(r.atMs)), ("expiresAtMs", .int(r.expiresAtMs)), ("state", .text(r.state)),
        ])
    }

    static func cbor(_ r: AuditRow) -> CBOR {
        .map([
            ("seq", .unsigned(r.seq)), ("atMs", .int(r.atMs)), ("actor", .text(r.actor)), ("role", .text(r.role)),
            ("principal", .text(r.principal)), ("by", .text(r.by)), ("what", .text(r.what)), ("target", .text(r.target)),
            ("result", .text(r.result)), ("count", .unsigned(r.count)),
        ])
    }
}

/// The demo's approval keys: one software key per home, and no Face ID, so
/// anyone can try the demo.
@MainActor
public final class SimulatedKeyring: ApprovalKeyring, ApprovalUnlock {
    private var kept: [String: SoftwareSigner] = [:]
    private var waiting: [String: SoftwareSigner] = [:]
    private var home = ""
    /// How many times the demo would have asked for Face ID.
    public private(set) var unlocks = 0
    /// How many approvals ended, as each must.
    public private(set) var ends = 0
    /// For a test: keeping a key fails, as a full Keychain would.
    public var keepFails = false

    public init() {}

    public func unlock(home: String, reason: String) async throws -> ApprovalUnlock {
        self.home = home
        unlocks += 1
        return self
    }

    public func forget(home: String) {
        kept[home] = nil
        waiting[home] = nil
    }
    public func existing() throws -> ApprovalSigner? { kept[home] }
    public func pending() throws -> ApprovalSigner? { waiting[home] }
    public func make() throws -> ApprovalSigner { SoftwareSigner() }
    public func keep(_ signer: ApprovalSigner) throws {
        guard !keepFails, let s = signer as? SoftwareSigner else { throw ApprovalKeyNotKept() }
        kept[home] = s
    }
    public func keepPending(_ signer: ApprovalSigner) throws {
        guard !keepFails, let s = signer as? SoftwareSigner else { throw ApprovalKeyNotKept() }
        waiting[home] = s
    }
    public func promote() throws {
        guard let s = waiting.removeValue(forKey: home) else { return }
        kept[home] = s
    }
    public func dropPending() { waiting[home] = nil }
    public func end() { ends += 1 }
}

/// The demo's help desk: a ticket number and a support offer signed by the
/// demo's offer key.
@MainActor
public final class SimulatedDesk: SupportDesk {
    private var next = 1043

    public init() {}

    public var isOpen: Bool { true }

    public func open(problem: String) async throws -> SignedOffer {
        defer { next += 1 }
        return SimulatedAccess.offer(support: true, ticket: "FTW-\(next)", nowMs: Date().timeIntervalSince1970 * 1000)
    }
}
