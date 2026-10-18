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
    /// This home's key, or nil when the phone has none. Throws
    /// `ApprovalKeyLost` when the key is there but can no longer sign: a
    /// new Face ID enrolment voids it.
    func existing() throws -> ApprovalSigner?
    /// A replacement made but not yet known to have reached the box, kept
    /// beside the current key so neither is stranded.
    func pending() throws -> ApprovalSigner?
    /// A new key, not yet kept anywhere.
    func make() throws -> ApprovalSigner
    /// Keep `signer` as this home's key. Done before the box hears of it,
    /// so a key the box took is never one the phone lost.
    func keep(_ signer: ApprovalSigner) throws
    /// Keep a replacement beside the current key.
    func keepPending(_ signer: ApprovalSigner) throws
    /// The replacement reached the box: it becomes this home's key.
    func promote() throws
    /// The box refused the replacement: it goes.
    func dropPending()
    /// The approval is over; the Face ID it was given covers nothing more.
    func end()
}

/// The person backed out of Face ID. Nothing was sent.
public struct ApprovalCancelled: Error, Equatable {
    public init() {}
}

/// The key is there but cannot sign: Face ID was enrolled again.
public struct ApprovalKeyLost: Error, Equatable {
    public init() {}
}

/// Face ID is locked after too many tries; the passcode opens it again.
public struct ApprovalLocked: Error, Equatable {
    public init() {}
}

/// The phone could not sign, for a reason that is not a lost key.
public struct ApprovalSigningFailed: Error, Equatable {
    public init() {}
}

/// The phone could not keep a key, so it sent nothing that would need it.
public struct ApprovalKeyNotKept: Error, Equatable {
    public init() {}
}

/// What the owner grants: a subset of what an offer asks, or a row's new
/// rights.
public struct Grant: Equatable, Sendable {
    public var scopes: [String]
    public var ops: [String]
    public var caps: Caps
    public var lengthMs: Int64

    /// An end the grant keeps as it is, instead of a new length.
    public var expiresAtMs: Int64?

    public init(scopes: [String], ops: [String], caps: Caps, lengthMs: Int64, expiresAtMs: Int64? = nil) {
        self.scopes = Approval.sorted(scopes)
        self.ops = Approval.sorted(ops)
        self.caps = caps
        self.lengthMs = lengthMs
        self.expiresAtMs = expiresAtMs
    }

    /// The lengths an owner may pick, longest last: within the role's, the
    /// offer's and the box's. `boxMs` is what the box's `agent.list` says
    /// for the role; nil is a box that says nothing, which takes 30 days
    /// for an assistant.
    public static func lengths(role: String, offeredS: UInt64? = nil, boxMs: Int64? = nil) -> [Int64] {
        let day: Int64 = 86_400_000
        var most = min(AccessWire.longestMs(role), boxMs ?? AccessWire.unstatedLongestMs(role))
        if let offeredS, offeredS > 0 { most = min(most, Int64(offeredS) * 1000) }
        let picks = role == AccessWire.roleSupport ? [day, 3 * day, 7 * day, 14 * day] : [day, 7 * day, 30 * day, 90 * day, 365 * day]
        let fit = picks.filter { $0 <= most }
        return fit.isEmpty ? [most] : fit
    }

    /// The length an offer starts at: 30 days for an assistant and a week
    /// for Sourceful, or the longest pick below that.
    public static func startLength(role: String, in picks: [Int64]) -> Int64 {
        let start: Int64 = (role == AccessWire.roleSupport ? 7 : 30) * 86_400_000
        return picks.last(where: { $0 <= start }) ?? picks.first ?? start
    }

    /// What the owner grants from an offer: what it reads, and control only
    /// when ticked. Never more than it asks, and never past the box's own
    /// limits.
    public static func from(_ offer: GrantOffer, control: Bool, lengthMs: Int64, boxMs: Int64? = nil, setup: Bool = false) -> Grant {
        let allowed = Set(Contract.agentRoleScopes[offer.role] ?? [])
        let asked = Set(offer.scopes).intersection(allowed)
        var scopes = (control ? asked : asked.subtracting(AccessWire.controlScopes)).subtracting([AccessWire.scopeSetup])
        if setup, asked.contains(AccessWire.scopeSetup) { scopes.insert(AccessWire.scopeSetup) }
        let ops = offer.ops.filter { op in Contract.agentOps[op].map(scopes.contains) ?? false }
        var caps = Caps(perMin: min(offer.caps.perMin, 60))
        if scopes.contains(AccessWire.scopeHold) {
            caps.holdS = min(offer.caps.holdS, AccessWire.holdSRange.upperBound)
            caps.maxW = min(offer.caps.maxW, AccessWire.maxWRange.upperBound)
        }
        let longest = lengths(role: offer.role, offeredS: offer.ttlS, boxMs: boxMs).last ?? lengthMs
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
    public private(set) var invitations: [AgentInvitation] = []
    public private(set) var audit: [AuditRow] = []
    public private(set) var auditMore = false
    /// What the owner wrote for each support ticket, on this phone only.
    public private(set) var tickets: [TicketNote] = []
    /// Where each client lives, as the offer this phone approved said. The
    /// row carries only the client's id, which for a registered client is
    /// no address.
    public private(set) var clients: [ClientNote] = []
    /// The box's answer to `agent.list` has arrived this visit, so `keys`
    /// is the box's word and not a cache's: only then may this phone
    /// decide it has no key there.
    public private(set) var keysKnown = false
    /// The row or request a change is on its way for.
    public private(set) var working: String?
    /// Rows the owner removed whose answer has not come back. They leave
    /// the lists at once, and come back only if the box refuses.
    public private(set) var removing: Set<String> = []
    /// Rows the box has said are gone. An answer to `agent.list` sent
    /// before the box removed one still holds it, and must not bring it
    /// back.
    @ObservationIgnored private var removed: Set<String> = []
    /// Why each failed removal failed, kept until the read after the last
    /// removal so that read does not wipe it.
    @ObservationIgnored private var refused: [String: String] = [:]
    /// What went wrong, in words that say what happens now.
    public private(set) var help: String?

    public let site: SiteModel
    public let signedFor: SignedFor
    @ObservationIgnored let keyring: ApprovalKeyring?
    @ObservationIgnored let wallMs: @MainActor () -> Double
    @ObservationIgnored let invitationLookup: OfferLookup
    /// Box wall clock minus this phone's, once the box has said
    /// `E_CLOCK_SKEW`.
    @ObservationIgnored private var boxOffsetMs: Double = 0

    /// For the simulated home: a box key and a device id the simulated box
    /// knows too.
    public static let demoFor = SignedFor(boxKey: Bytes(repeating: 0x5a, count: 32), deviceID: "demoPh01")

    public init(site: SiteModel, signedFor: SignedFor, keyring: ApprovalKeyring?, wallMs: @escaping @MainActor () -> Double = { Date().timeIntervalSince1970 * 1000 }, invitationLookup: OfferLookup = .current()) {
        self.site = site
        self.signedFor = signedFor
        self.keyring = keyring
        self.wallMs = wallMs
        self.invitationLookup = invitationLookup
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

    /// What goes beside a grant's name: the ticket for support, else where
    /// the client lives, else its id, so a name of its own choosing never
    /// stands alone.
    public func place(_ row: AgentRow) -> String {
        if row.isSupport { return AccessWords.format("Ticket %@", AccessWords.clean(row.principal.ticket)) }
        let host = host(row)
        if !host.isEmpty { return host }
        let idName = AccessWords.format("Assistant %@", row.id)
        return AccessWords.name(row) == idName ? "" : idName
    }

    /// What the client asked for when this phone approved it.
    public func asked(_ row: AgentRow) -> ClientNote? {
        clients.first { $0.id == row.id }
    }

    /// A grant's name and where its client lives, for the system's Face ID
    /// sheet: the name is the client's own word, the host is not.
    public func who(_ row: AgentRow) -> (name: String, host: String) {
        (AccessWords.name(row), host(row))
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

    public var assistants: [AgentRow] { (list?.agents ?? []).filter { !$0.isSupport && !removing.contains($0.id) } }
    public var support: [AgentRow] { (list?.agents ?? []).filter { $0.isSupport && !removing.contains($0.id) } }
    public var pending: [AgentRequest] { (list?.requests ?? []).filter { $0.pending && !removing.contains($0.agent) } }

    /// The box holds an approval key for this phone.
    public var boxHasKey: Bool { list?.keys.contains { $0.deviceId == signedFor.deviceID } ?? false }

    public func row(_ id: String) -> AgentRow? { list?.agents.first { $0.id == id } }

    var nowMs: Int64 { Int64((wallMs() + boxOffsetMs).rounded()) }

    /// The home the approval key is kept under. The simulated home has no
    /// id of its own.
    var keyHome: String? { site.siteId ?? (site.isDemo ? "demo" : nil) }

    /// The longest grant the box says it takes for a role, once it has
    /// answered `agent.list` this visit. Nil means it said nothing.
    public func boxLongestMs(_ role: String) -> Int64? {
        keysKnown ? list?.longestMs[role] : nil
    }

    // MARK: Reading

    public func refresh() async {
        guard available else { return }
        do {
            list = withoutRemoved(AgentList(try await site.ask(AccessWire.msgList, .emptyMap)))
            keysKnown = true
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

    public var invitationsAvailable: Bool { available && site.session.caps.contains(Contract.capAccessInvites) }

    public func refreshInvitations() async {
        guard invitationsAvailable else { return }
        do {
            let rows = (try await site.ask(InvitationWire.list, .emptyMap))["invitations"]?.array?.compactMap(AgentInvitation.init) ?? []
            let newlyClaimed = rows.contains { row in
                row.state == "claimed" && !invitations.contains(where: { $0.id == row.id && $0.state == "claimed" })
            }
            invitations = rows
            if newlyClaimed { await refresh() }
        } catch { help = words(error) }
    }

    public func cancelInvitation(_ invitation: AgentInvitation) async -> AgentInvitation? {
        do {
            let answer = try await site.ask(InvitationWire.cancel, .map([("id", .text(invitation.id))]))
            let row = answer["invitation"].flatMap(AgentInvitation.init)
            await refreshInvitations(); await refresh(); return row
        } catch { help = words(error); return nil }
    }

    @discardableResult
    public func createInvitation(_ draft: InvitationDraft, home: String, label: String, grant: Grant, claimSeconds: Int64) async
        -> AgentInvitation?
    {
        let result: AgentInvitation? = await signed(
            AccessWords.text("Create an invitation to this home"), target: "invitation", retrySkew: false,
            onSpare: { signer in
                guard var request = draft.request else { return }
                request.sig = try signer.sign(try request.signedBytes(self.signedFor))
                draft.request = request
            }
        ) { signer in
            if draft.request == nil {
                let clock = try await self.site.ask(InvitationWire.list, .emptyMap)
                guard clock["clockReady"]?.bool == true, let boxMs = clock["nowMs"]?.int64, boxMs > 0 else {
                    throw BoxRefusal(detail: ErrorMsg(code: "E_UNAVAILABLE", retryable: true, args: ["subsystem": .text("clock")]))
                }
                self.boxOffsetMs = Double(boxMs) - self.wallMs()
                let at = self.nowMs, end = self.expiry(grant.lengthMs)
                var m = InvitationCreate(
                    id: draft.id, home: home, label: label, hash: InvitationWire.hash(home: home, secret: draft.secret), grant: grant,
                    claimUntilMs: min(at + claimSeconds * 1000, end), expiresAtMs: end, atMs: at)
                m.sig = try signer.sign(try m.signedBytes(self.signedFor)); draft.request = m
            }
            guard let m = draft.request else { return nil }
            let answer = try await self.site.ask(InvitationWire.create, m.cbor)
            return answer["invitation"].flatMap(AgentInvitation.init)
        }
        if let result { draft.receipt = result }
        await refreshInvitations()
        if result == nil, let row = invitations.first(where: { $0.id == draft.id }) { draft.receipt = row }
        if draft.receipt?.state == "pending" { await publishInvitation(draft) }
        return draft.receipt
    }

    public func invitationCode(_ draft: InvitationDraft) -> String? {
        guard let alias = draft.alias, nowMs < alias.expiresAtMs else { return nil }
        return draft.code
    }

    public func publishInvitation(_ draft: InvitationDraft) async {
        guard let receipt = draft.receipt, receipt.state == "pending" else { return }
        working = "invitationCode"
        defer { working = nil }
        let proof = InvitationWire.code(home: receipt.home, box: receipt.box, secret: draft.secret)
        do { draft.alias = try await invitationLookup.publishInvitation(proof); help = nil } catch {
            help = AccessWords.text("Waiting for the box to publish the code. Keep this page open and retry the same invitation.")
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
        if list?.agents.contains(where: { $0.key == offer.key }) == true {
            help = AccessWords.offer(.used)
            return nil
        }
        let principal = Principal(client: Self.cut(offer.client), clientId: Self.cut(offer.clientId), ticket: Self.cut(offer.ticket))
        let reason = AccessWords.format("Let %@ from %@ reach your home", AccessWords.clientName(offer), offer.clientHost)
        return await signed(reason, target: "offer") { signer in
            var add = AgentAdd(key: offer.key, role: offer.role, scopes: grant.scopes, ops: grant.ops, caps: grant.caps,
                               expiresAtMs: self.expiry(grant.lengthMs), principal: principal, atMs: self.nowMs)
            add.sig = try signer.sign(try Approval.addBytes(self.signedFor, add))
            let ok = try await self.site.ask(AccessWire.msgAdd, add.cbor)
            guard let row = ok["agent"].flatMap(AgentRow.init) else { return nil }
            self.clients.removeAll { $0.id == row.id }
            self.clients.append(ClientNote(id: row.id, host: offer.clientHost, verified: offer.verified,
                                           askedOps: offer.ops, askedCaps: offer.caps))
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
        let reason = reasonFor("Change what %@ may do", "Change what %@ from %@ may do", row)
        let changed: AgentRow? = await signed(reason, target: row.id) { signer in
            var m = AgentWiden(id: row.id, epoch: row.epoch, scopes: grant.scopes, ops: grant.ops, caps: grant.caps,
                               expiresAtMs: grant.expiresAtMs ?? self.expiry(grant.lengthMs), atMs: self.nowMs)
            m.sig = try signer.sign(try Approval.widenBytes(self.signedFor, m, key: row.key))
            let ok = try await self.site.ask(AccessWire.msgWiden, m.cbor)
            return ok["agent"].flatMap(AgentRow.init) ?? row
        }
        return changed != nil
    }

    /// Remove access at once: the row and its requests leave the lists in
    /// this change, the one the owner's swipe animates, and the box hears
    /// of it after. No Face ID: removing is always safe.
    public func remove(_ row: AgentRow) {
        guard removing.insert(row.id).inserted else { return }
        Task { await sendRevoke(row) }
    }

    /// `remove`, waiting for the box. True when the row is gone; false when
    /// the box refused and the row is back, or another removal of it is on
    /// its way.
    @discardableResult
    public func revoke(_ row: AgentRow) async -> Bool {
        guard removing.insert(row.id).inserted else { return false }
        return await sendRevoke(row)
    }

    /// Each removal goes to the box at once and on its own. Its answer
    /// changes nothing the owner sees unless the box refused. The box is
    /// read once, after the last answer, rather than once per removal.
    private func sendRevoke(_ row: AgentRow) async -> Bool {
        var gone = true
        do {
            _ = try await site.ask(AccessWire.msgRevoke, .map([("id", .text(row.id))]))
        } catch let r as BoxRefusal where r.detail.code == "E_NOT_FOUND" {
            // Already gone, whoever removed it.
        } catch {
            gone = false
            refused[row.id] = words(error)
            help = refused[row.id]
        }
        if gone {
            removed.insert(row.id)
            list = list.map(withoutRemoved)
        }
        removing.remove(row.id)
        guard removing.isEmpty else { return gone }
        await refresh()
        // A failure stands while its row does. A removal whose answer was
        // lost may still have gone through, and then the read says so.
        if let why = refused.first(where: { id, _ in self.row(id) != nil })?.value { help = why }
        refused = [:]
        return gone
    }

    /// The box's list without the rows it has already said are gone, and
    /// without their requests.
    private func withoutRemoved(_ l: AgentList) -> AgentList {
        guard !removed.isEmpty else { return l }
        var l = l
        l.agents.removeAll { removed.contains($0.id) }
        l.requests.removeAll { removed.contains($0.agent) }
        return l
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
        guard AccessWords.approvable(request) else {
            help = AccessWords.text("This request has something this app can't show you, so it can only be declined.")
            return false
        }
        let reason = row(request.agent).map { reasonFor("Let %@ make this change", "Let %@ from %@ make this change", $0) }
            ?? AccessWords.format("Let %@ make this change", agentName(request.agent))
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
    /// box takes it. One Face ID. The new key is kept beside the old one
    /// before the box hears of it, so whichever the box ends up holding,
    /// the phone still has.
    @discardableResult
    public func replaceKey() async -> Bool {
        guard let keyring, let home = keyHome else { return false }
        working = "key"
        defer { working = nil }
        do {
            if !keysKnown { await refresh() }
            guard keysKnown else { throw SessionError.noCarrier }
            let unlock = try await keyring.unlock(home: home, reason: AccessWords.text("Replace the approval key on this phone"))
            defer { unlock.end() }
            guard let old = try unlock.existing() else { throw ApprovalKeyLost() }
            let fresh = try unlock.make()
            do {
                try unlock.keepPending(fresh)
            } catch {
                throw ApprovalKeyNotKept()
            }
            do {
                try await retryingSkew {
                    let atMs = self.nowMs
                    let msg = Approval.keySetBytes(self.signedFor, atMs: atMs, pub: fresh.publicKey)
                    _ = try await self.site.ask(AccessWire.msgKeySet, .map([
                        ("pub", .bytes(fresh.publicKey)), ("atMs", .int(atMs)), ("sig", .bytes(try fresh.sign(msg))),
                        ("prevSig", .bytes(try old.sign(msg))),
                    ]).deterministic)
                }
            } catch let r as BoxRefusal {
                // The box said no: it still holds the old key.
                unlock.dropPending()
                throw r
            }
            try? unlock.promote()
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
    /// the box says this phone's clock is off. The box's own list of keys
    /// decides whether this phone registers one: never a cached list.
    private func signed<T>(
        _ reason: String, target: String, retrySkew: Bool = true, onSpare: (@MainActor (ApprovalSigner) throws -> Void)? = nil,
        _ work: @escaping @MainActor (ApprovalSigner) async throws -> T?
    ) async -> T? {
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
        if !keysKnown { await refresh() }
        guard keysKnown else {
            help = help ?? AccessWords.help(SessionError.noCarrier)
            return nil
        }
        do {
            let unlock = try await keyring.unlock(home: home, reason: reason)
            defer { unlock.end() }
            let keys = try await registered(unlock)
            let out: T?
            do {
                if retrySkew { out = try await retryingSkew { try await work(keys.signer) } } else { out = try await work(keys.signer) }
                if keys.isPending { try? unlock.promote() }
            } catch let r as BoxRefusal where r.detail.code == "E_BAD_SIGNATURE" && r.detail.args["field"] == nil && keys.spare != nil {
                // A replacement the box took though its answer never came
                // back: the spare is the key the box holds.
                try onSpare?(keys.spare!)
                if retrySkew { out = try await retryingSkew { try await work(keys.spare!) } } else { out = try await work(keys.spare!) }
                try? unlock.promote()
            }
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
    /// A first key is kept before the box hears of it. With a replacement
    /// waiting, the current key signs first and the replacement is the
    /// spare.
    private func registered(_ unlock: ApprovalUnlock) async throws -> (signer: ApprovalSigner, spare: ApprovalSigner?, isPending: Bool) {
        let have = try unlock.existing()
        let waiting = try? unlock.pending()
        if boxHasKey {
            if let have { return (have, waiting, false) }
            if let waiting { return (waiting, nil, true) }
            throw ApprovalKeyLost()
        }
        let signer: ApprovalSigner
        if let have {
            signer = have
        } else {
            signer = try unlock.make()
            do {
                try unlock.keep(signer)
            } catch {
                throw ApprovalKeyNotKept()
            }
        }
        try await retryingSkew {
            let atMs = self.nowMs
            let msg = Approval.keySetBytes(self.signedFor, atMs: atMs, pub: signer.publicKey)
            _ = try await self.site.ask(AccessWire.msgKeySet, .map([
                ("pub", .bytes(signer.publicKey)), ("atMs", .int(atMs)), ("sig", .bytes(try signer.sign(msg))),
            ]).deterministic)
        }
        if var l = list {
            l.keys.append(ApprovalKeyInfo(deviceId: signedFor.deviceID, setAtMs: nowMs))
            list = l
        }
        return (signer, nil, false)
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
        row(id).map(AccessWords.name) ?? AccessWords.format("Assistant %@", AccessWords.clean(id))
    }

    /// The Face ID sheet's line: the name, and the host beside it when the
    /// phone knows one.
    func reasonFor(_ bare: String, _ withHost: String, _ row: AgentRow) -> String {
        let (name, host) = who(row)
        return host.isEmpty || row.isSupport ? AccessWords.format(bare, name) : AccessWords.format(withHost, name, host)
    }

    /// A principal field cut to 256 bytes of UTF-8, at a character's edge.
    static func cut(_ text: String, max: Int = 256) -> String {
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out
    }

    func words(_ error: Error) -> String? {
        AccessWords.help(error)
    }
}
