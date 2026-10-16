import Foundation
import Observation

/// The phone's approval key for one home, behind one Face ID.
///
/// The app makes it in the Secure Enclave, usable only after Face ID with
/// the current enrolment (`biometryCurrentSet`), and keeps it in the
/// Keychain under the home. Each home has its own key, so replacing it at
/// one box leaves the others alone.
@MainActor
public protocol ApprovalKeyring: AnyObject {
    /// One Face ID, with `reason` on the system's sheet. Every signature
    /// through the answer is covered by it. Throws `ApprovalCancelled` when
    /// the person backs out.
    func unlock(home: String, reason: String) async throws -> ApprovalUnlock
    /// Drop a home's key, when the phone forgets the home.
    func forget(home: String)
}

@MainActor
public protocol ApprovalUnlock: AnyObject {
    /// This home's key, or nil when the phone has none. Throws when the key
    /// is there but can no longer sign: a new Face ID enrolment voids it.
    func existing() throws -> ApprovalSigner?
    /// A new key, not yet this home's.
    func make() throws -> ApprovalSigner
    /// Make `signer` this home's key, once the box has it.
    func keep(_ signer: ApprovalSigner)
}

/// The person backed out of Face ID. Nothing was sent.
public struct ApprovalCancelled: Error, Equatable {
    public init() {}
}

/// The key is there but cannot sign: Face ID was enrolled again.
public struct ApprovalKeyLost: Error, Equatable {
    public init() {}
}

/// What the owner grants: a subset of what an offer asks, or a row's new
/// rights.
public struct Grant: Equatable, Sendable {
    public var scopes: [String]
    public var ops: [String]
    public var caps: Caps
    public var lengthMs: Int64

    public init(scopes: [String], ops: [String], caps: Caps, lengthMs: Int64) {
        self.scopes = Approval.sorted(scopes)
        self.ops = Approval.sorted(ops)
        self.caps = caps
        self.lengthMs = lengthMs
    }

    /// The lengths an owner may pick, longest last, within the role's.
    public static func lengths(role: String, offeredS: UInt64? = nil) -> [Int64] {
        let day: Int64 = 86_400_000
        var most = AccessWire.longestMs(role)
        if let offeredS, offeredS > 0 { most = min(most, Int64(offeredS) * 1000) }
        let picks = role == AccessWire.roleSupport ? [day, 3 * day, 7 * day, 14 * day] : [day, 7 * day, 30 * day]
        let fit = picks.filter { $0 <= most }
        return fit.isEmpty ? [most] : fit
    }

    /// What the owner grants from an offer: what it reads, and control only
    /// when ticked. Never more than it asks, and never past the box's own
    /// limits.
    public static func from(_ offer: GrantOffer, control: Bool, lengthMs: Int64) -> Grant {
        let allowed = Set(Contract.agentRoleScopes[offer.role] ?? [])
        let asked = Set(offer.scopes).intersection(allowed)
        let scopes = control ? asked : asked.subtracting(AccessWire.controlScopes)
        let ops = offer.ops.filter { op in Contract.agentOps[op].map(scopes.contains) ?? false }
        var caps = Caps(perMin: min(offer.caps.perMin, 60))
        if scopes.contains(AccessWire.scopeHold) {
            caps.holdS = min(offer.caps.holdS, AccessWire.holdSRange.upperBound)
            caps.maxW = min(offer.caps.maxW, AccessWire.maxWRange.upperBound)
        }
        let longest = lengths(role: offer.role, offeredS: offer.ttlS).last ?? lengthMs
        return Grant(scopes: Array(scopes), ops: ops, caps: caps, lengthMs: min(lengthMs, longest))
    }

    /// A row's rights as they stand, with a new length.
    public static func from(_ row: AgentRow, control: Bool? = nil, lengthMs: Int64) -> Grant {
        Grant(scopes: row.scopes, ops: row.ops, caps: row.caps, lengthMs: lengthMs)
    }

    public var hasControl: Bool { !AccessWire.controlScopes.isDisjoint(with: scopes) }
}

/// Who may reach this home other than its paired phones and watches: the
/// assistants and Sourceful support the owner let in, what they asked for,
/// and what they did (docs/agents.md in srcfl/ftw).
///
/// The box decides everything; this asks it, shows what it said and sends
/// the owner's word. Granting, changing a grant and approving a request are
/// signed with this phone's approval key behind one Face ID. Removing access
/// and declining a request are not, so they take one tap.
@Observable
@MainActor
public final class AccessModel {
    /// Nil until the box has answered once.
    public private(set) var list: AgentList?
    public private(set) var audit: [AuditRow] = []
    public private(set) var auditMore = false
    /// What the owner wrote for each support ticket, on this phone only.
    public private(set) var tickets: [TicketNote] = []
    /// Where each client lives, as the offer this phone approved said. The
    /// row carries only the client's id, which for a registered client is
    /// no address.
    public private(set) var clients: [ClientNote] = []
    /// The row or request a change is on its way for.
    public private(set) var working: String?
    /// What went wrong, in words that say what happens now.
    public private(set) var help: String?

    public let site: SiteModel
    public let signedFor: SignedFor
    @ObservationIgnored let keyring: ApprovalKeyring?
    @ObservationIgnored let wallMs: @MainActor () -> Double
    /// Box wall clock minus this phone's, once the box has said
    /// `E_CLOCK_SKEW`.
    @ObservationIgnored private var boxOffsetMs: Double = 0

    /// For the simulated home: a box key and a device id the simulated box
    /// knows too.
    public static let demoFor = SignedFor(boxKey: Bytes(repeating: 0x5a, count: 32), deviceID: "demoPh01")

    public init(site: SiteModel, signedFor: SignedFor, keyring: ApprovalKeyring?, wallMs: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.site = site
        self.signedFor = signedFor
        self.keyring = keyring
        self.wallMs = wallMs
        // The rows the last visit saw, so the list opens on them; the box's
        // answer replaces them within a round trip.
        if let rows = site.keptFile([AgentRow].self, "access") { list = AgentList(agents: rows) }
        tickets = site.keptFile([TicketNote].self, "tickets") ?? []
        clients = site.keptFile([ClientNote].self, "clients") ?? []
        site.keepFile("access") { [weak self] in self?.list?.agents }
        site.keepFile("tickets") { [weak self] in self?.tickets }
        site.keepFile("clients") { [weak self] in self?.clients }
    }

    /// Where a grant's client lives: the offer's host when this phone
    /// approved it, else the host of a client id that is an address, else
    /// nothing.
    public func host(_ row: AgentRow) -> String {
        clients.first { $0.id == row.id }?.host ?? AccessWords.host(row)
    }

    /// Whether FTW Cloud knew the client when this phone approved it. Nil
    /// when another phone or the box's page did.
    public func verified(_ row: AgentRow) -> Bool? {
        clients.first { $0.id == row.id }?.verified
    }

    /// Keep what the owner wrote for a ticket beside its id.
    public func note(_ ticket: String, problem: String) {
        tickets.removeAll { $0.ticket == ticket }
        tickets.append(TicketNote(ticket: ticket, problem: problem, atMs: wallMs()))
        site.persistNow()
    }

    public func problem(_ row: AgentRow) -> String? {
        tickets.first { $0.ticket == row.principal.ticket }?.problem
    }

    /// The box takes agents and this phone is an owner there.
    public var available: Bool {
        site.heardFromBox && site.canConfigure && site.session.caps.contains(Contract.capAccessAgents)
    }

    public var assistants: [AgentRow] { (list?.agents ?? []).filter { !$0.isSupport } }
    public var support: [AgentRow] { (list?.agents ?? []).filter(\.isSupport) }
    public var pending: [AgentRequest] { (list?.requests ?? []).filter(\.pending) }

    /// The box holds an approval key for this phone.
    public var boxHasKey: Bool { list?.keys.contains { $0.deviceId == signedFor.deviceID } ?? false }

    public func row(_ id: String) -> AgentRow? { list?.agents.first { $0.id == id } }

    var nowMs: Int64 { Int64((wallMs() + boxOffsetMs).rounded()) }

    /// The home the approval key is kept under. The simulated home has no
    /// id of its own.
    var keyHome: String? { site.siteId ?? (site.isDemo ? "demo" : nil) }

    // MARK: Reading

    public func refresh() async {
        guard available else { return }
        do {
            list = AgentList(try await site.ask(AccessWire.msgList, .emptyMap))
            help = nil
        } catch {
            help = words(error)
        }
    }

    /// The newest page of the audit log, or the next older one.
    public func loadAudit(more: Bool = false) async {
        guard available else { return }
        var body: [(String, CBOR)] = [("n", .unsigned(100))]
        if more, let last = audit.last { body.append(("beforeSeq", .unsigned(last.seq))) }
        do {
            let page = AuditPage(try await site.ask(AccessWire.msgAudit, .map(body)))
            audit = more ? audit + page.rows : page.rows
            auditMore = page.more
        } catch {
            help = words(error)
        }
    }

    // MARK: Granting

    /// Grant what the owner chose from an offer, behind one Face ID. A phone
    /// whose key the box does not hold yet registers it under the same Face
    /// ID first.
    @discardableResult
    public func approve(_ offer: GrantOffer, grant: Grant) async -> AgentRow? {
        guard !grant.scopes.isEmpty else {
            help = AccessWords.text("Choose at least one thing it may do.")
            return nil
        }
        let principal = Principal(client: String(offer.client.prefix(256)), clientId: String(offer.clientId.prefix(256)), ticket: offer.ticket)
        let reason = AccessWords.format("Let %@ reach your home", AccessWords.clientName(offer))
        return await signed(reason, target: "offer") { signer in
            var add = AgentAdd(key: offer.key, role: offer.role, scopes: grant.scopes, ops: grant.ops, caps: grant.caps,
                               expiresAtMs: self.expiry(grant.lengthMs), principal: principal, atMs: self.nowMs)
            add.sig = try signer.sign(try Approval.addBytes(self.signedFor, add))
            let ok = try await self.site.ask(AccessWire.msgAdd, add.cbor)
            guard let row = ok["agent"].flatMap(AgentRow.init) else { return nil }
            self.clients.removeAll { $0.id == row.id }
            self.clients.append(ClientNote(id: row.id, host: offer.clientHost, verified: offer.verified))
            self.site.persistNow()
            return row
        }
    }

    /// Change a grant: wider, narrower or longer. Signed like a grant.
    @discardableResult
    public func widen(_ row: AgentRow, to grant: Grant) async -> Bool {
        guard !grant.scopes.isEmpty else {
            help = AccessWords.text("Choose at least one thing it may do.")
            return false
        }
        let reason = AccessWords.format("Change what %@ may do", AccessWords.name(row))
        let changed: AgentRow? = await signed(reason, target: row.id) { signer in
            var m = AgentWiden(id: row.id, epoch: row.epoch, scopes: grant.scopes, ops: grant.ops, caps: grant.caps,
                               expiresAtMs: self.expiry(grant.lengthMs), atMs: self.nowMs)
            m.sig = try signer.sign(try Approval.widenBytes(self.signedFor, m, key: row.key))
            let ok = try await self.site.ask(AccessWire.msgWiden, m.cbor)
            return ok["agent"].flatMap(AgentRow.init) ?? row
        }
        return changed != nil
    }

    /// Remove access at once. No Face ID: removing is always safe.
    @discardableResult
    public func revoke(_ row: AgentRow) async -> Bool {
        working = row.id
        defer { working = nil }
        do {
            _ = try await site.ask(AccessWire.msgRevoke, .map([("id", .text(row.id))]))
            if var l = list {
                l.agents.removeAll { $0.id == row.id }
                l.requests.removeAll { $0.agent == row.id }
                list = l
            }
            help = nil
            await refresh()
            return true
        } catch let r as BoxRefusal where r.detail.code == "E_NOT_FOUND" {
            // Already gone, whoever removed it.
            await refresh()
            return true
        } catch {
            help = words(error)
            return false
        }
    }

    // MARK: Requests

    /// Approve a request behind Face ID, signing exactly what was shown, or
    /// decline it with one tap.
    @discardableResult
    public func answer(_ request: AgentRequest, approve: Bool) async -> Bool {
        guard approve else {
            working = request.reqId
            defer { working = nil }
            do {
                _ = try await site.ask(AccessWire.msgConfirm, .map([("reqId", .text(request.reqId)), ("approve", .bool(false))]))
                help = nil
                await refresh()
                return true
            } catch {
                await refresh()
                help = words(error)
                return false
            }
        }
        let reason = AccessWords.format("Let %@ make this change", agentName(request.agent))
        let done: Bool? = await signed(reason, target: request.reqId) { signer in
            let atMs = self.nowMs
            let sig = try signer.sign(Approval.confirmBytes(self.signedFor, reqId: request.reqId, atMs: atMs, request: request))
            _ = try await self.site.ask(AccessWire.msgConfirm, .map([
                ("reqId", .text(request.reqId)), ("approve", .bool(true)), ("atMs", .int(atMs)), ("sig", .bytes(sig)),
            ]).deterministic)
            return true
        }
        return done ?? false
    }

    // MARK: The approval key

    /// A new approval key for this home, with the old key's signature so the
    /// box takes it. One Face ID.
    @discardableResult
    public func replaceKey() async -> Bool {
        guard let keyring, let home = keyHome else { return false }
        working = "key"
        defer { working = nil }
        do {
            let unlock = try await keyring.unlock(home: home, reason: AccessWords.text("Replace the approval key on this phone"))
            guard let old = try unlock.existing() else { throw ApprovalKeyLost() }
            let fresh = try unlock.make()
            try await retryingSkew {
                let atMs = self.nowMs
                let msg = Approval.keySetBytes(self.signedFor, atMs: atMs, pub: fresh.publicKey)
                _ = try await self.site.ask(AccessWire.msgKeySet, .map([
                    ("pub", .bytes(fresh.publicKey)), ("atMs", .int(atMs)), ("sig", .bytes(try fresh.sign(msg))),
                    ("prevSig", .bytes(try old.sign(msg))),
                ]).deterministic)
            }
            unlock.keep(fresh)
            help = nil
            await refresh()
            return true
        } catch {
            help = words(error)
            return false
        }
    }

    // MARK: Signing

    /// One Face ID, the key registered at the box if it has none for this
    /// phone, then `work` with the key; again once with the box's time if
    /// the box says this phone's clock is off.
    private func signed<T>(_ reason: String, target: String, _ work: @escaping @MainActor (ApprovalSigner) async throws -> T?) async -> T? {
        guard let keyring, let home = keyHome else {
            help = AccessWords.text("This phone can't approve on its own. Use your box's page.")
            return nil
        }
        guard available else {
            help = AccessWords.help(SessionError.noCarrier)
            return nil
        }
        working = target
        defer { working = nil }
        do {
            if list == nil { await refresh() }
            let unlock = try await keyring.unlock(home: home, reason: reason)
            let signer = try await registered(unlock)
            let out = try await retryingSkew { try await work(signer) }
            help = nil
            await refresh()
            return out
        } catch {
            await refresh()
            help = words(error)
            return nil
        }
    }

    /// This home's key, registered at the box if the box has none for this
    /// phone: the one natural moment, under the Face ID the owner just gave.
    private func registered(_ unlock: ApprovalUnlock) async throws -> ApprovalSigner {
        let have = try unlock.existing()
        if boxHasKey {
            guard let have else { throw ApprovalKeyLost() }
            return have
        }
        let signer = try have ?? unlock.make()
        try await retryingSkew {
            let atMs = self.nowMs
            let msg = Approval.keySetBytes(self.signedFor, atMs: atMs, pub: signer.publicKey)
            _ = try await self.site.ask(AccessWire.msgKeySet, .map([
                ("pub", .bytes(signer.publicKey)), ("atMs", .int(atMs)), ("sig", .bytes(try signer.sign(msg))),
            ]).deterministic)
        }
        unlock.keep(signer)
        if var l = list {
            l.keys.append(ApprovalKeyInfo(deviceId: signedFor.deviceID, setAtMs: nowMs))
            list = l
        }
        return signer
    }

    /// Once more with the box's clock, when the box says this phone's is
    /// more than ten minutes off. The same Face ID covers it.
    private func retryingSkew<T>(_ attempt: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch let r as BoxRefusal where r.detail.code == "E_CLOCK_SKEW" {
            guard let boxMs = r.detail.args["boxMs"]?.double else { throw r }
            boxOffsetMs = boxMs - wallMs()
            return try await attempt()
        }
    }

    /// The expiry for a length, kept inside the role's longest even when
    /// this phone's clock runs a little ahead of the box's.
    func expiry(_ lengthMs: Int64) -> Int64 {
        nowMs + lengthMs - Approval.skewMs
    }

    // MARK: Words

    /// An agent row's name, or its id when the box no longer has it.
    public func agentName(_ id: String) -> String {
        row(id).map(AccessWords.name) ?? AccessWords.format("Assistant %@", id)
    }

    func words(_ error: Error) -> String? {
        AccessWords.help(error)
    }
}
