import Foundation
import Observation

/// Who can see this home, through the box's own roster. Reading is a GET;
/// inviting and removing are writes, so the box asks for a ceremony first.
///
/// An invite is the ordinary pairing code minted with the viewer role and a
/// shorter life. The role is never in the payload: a role its holder could
/// edit is not a role.
@Observable
@MainActor
public final class AccessModel: Activatable {
    public struct Member: Equatable, Sendable, Identifiable {
        /// The box's name for the row: the first eight characters of its key.
        public let id: String
        public let role: String
        public let addedAtMs: Double?
        public let lastSeenMs: Double?
        public let isThisPhone: Bool
    }

    public struct Invite: Equatable, Sendable {
        /// The whole QR payload. It may only leave as a square for a camera.
        public let url: String
        public let role: String
        public let expiresAtMs: Double
    }

    public enum Busy: Sendable { case none, inviting, revoking }

    public private(set) var members: [Member] = []
    public private(set) var loading = false
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var invite: Invite?
    public private(set) var busy: Busy = .none

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private let thisPhone: String?
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0
    @ObservationIgnored private var token = 0

    public init(site: SiteModel, thisPhone: String?) {
        self.site = site
        self.thisPhone = thisPhone
    }

    public var canManage: Bool { site.canConfigure && site.hasPassthrough }
    public var owners: Int { members.filter { $0.role == Contract.roleOwner }.count }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.canManage else { return nil }
                return "members"
            }, ask: { [weak self] in try await self?.load() })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    func load() async throws {
        token += 1
        let mine = token
        loading = true
        error = nil
        defer { if mine == token { loading = false } }
        do {
            let wire = try await site.callBox(.get, "/api/app-link/devices")
            guard mine == token else { return }
            members = (wire?["devices"]?.array ?? []).map { d in
                let id = d["id"]?.string ?? ""
                // A row from a box before roles is an owner.
                let role = d["role"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? Contract.roleOwner
                return Member(id: id, role: role, addedAtMs: d["added_at_ms"]?.number, lastSeenMs: d["last_seen_ms"]?.number, isThisPhone: id == thisPhone)
            }
            loaded = true
        } catch {
            guard mine == token else { return }
            self.error = (error as? BoxAPIError)?.help ?? "Your box didn't answer. Still trying."
            throw error
        }
    }

    /// Mint a code that admits a viewer. The role goes in the body, where the
    /// box reads it, and an answer naming any other role is refused here.
    @discardableResult
    public func inviteViewer() async -> Bool {
        busy = .inviting
        error = nil
        defer { busy = .none }
        do {
            let wire = try await site.callBox(.post, "/api/app-link/pairing", body: ["role": .string(Contract.roleViewer)])
            guard wire?["role"]?.string == Contract.roleViewer, let url = wire?["url"]?.string else {
                throw BoxAPIError(code: "E_BAD_BODY", help: "Your box didn't make a view-only invitation. Nothing has been shared.", status: nil)
            }
            invite = Invite(url: url, role: Contract.roleViewer, expiresAtMs: wire?["expires_at_ms"]?.number ?? 0)
            return true
        } catch {
            self.error = (error as? BoxAPIError)?.help ?? "That did not work. Nothing has changed."
            return false
        }
    }

    public func dismissInvite() { invite = nil }

    /// Withdraw a phone's access. The row goes on the box's answer alone.
    @discardableResult
    public func revoke(_ id: String) async -> Bool {
        busy = .revoking
        error = nil
        defer { busy = .none }
        do {
            _ = try await site.callBox(.delete, "/api/app-link/devices/\(LoadpointsModel.escape(id))")
            members.removeAll { $0.id == id }
            return true
        } catch let e as BoxAPIError where e.status == 404 {
            // Already gone is what was asked for.
            members.removeAll { $0.id == id }
            return true
        } catch {
            self.error = (error as? BoxAPIError)?.help ?? "That did not work. Nothing has changed."
            return false
        }
    }

    public static func roleLabel(_ role: String) -> String {
        Contract.roleLabels[role] ?? role
    }

    public func seen(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "not seen yet" }
        let since = site.nowMs - ms
        if since < 120_000 { return "here now" }
        if since < 3_600_000 { return "\(Int((since / 60_000).rounded())) min ago" }
        if since < 86_400_000 { return "\(Int((since / 3_600_000).rounded())) h ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// What the box sends when something at home matters, and what it has sent.
///
/// The rules are the box's document and govern every phone it can reach.
/// Each entry goes out whole on a save, flipped only on `enabled`, because
/// the box replaces a rule wholesale and a partial one would wipe the
/// thresholds it seeded.
@Observable
@MainActor
public final class NotifyModel: Activatable {
    /// The kinds the rules govern. box.unreachable is not one: the box cannot
    /// gate a message about its own absence.
    public static let ruleKinds = [
        "charging.connected", "charging.session_complete", "charging.interrupted",
        "update.installed", "driver.offline", "fuse.over_limit",
    ]

    public static let labels: [String: String] = [
        "charging.connected": "When the car is plugged in",
        "charging.session_complete": "When the car finishes charging",
        "charging.interrupted": "If charging stops before it is done",
        "update.installed": "When your box updates itself",
        "driver.offline": "If a device goes quiet",
        "fuse.over_limit": "If the house draws more than the fuse allows",
        "box.unreachable": "If your box goes out of reach",
    ]

    public struct Sent: Equatable, Sendable, Identifiable {
        public let title: String
        public let atMs: Double?
        public var id: String { "\(title)\(atMs ?? 0)" }
    }

    public enum Busy: Sendable { case none, saving, testing }

    public private(set) var boxEnabled = false
    public private(set) var rules: [String: Bool] = [:]
    public private(set) var availableKinds: [String] = []
    public private(set) var history: [Sent] = []
    public private(set) var oldBox = false
    public private(set) var busy: Busy = .none
    public private(set) var error: String?
    public private(set) var testSent = false

    @ObservationIgnored private unowned let site: SiteModel
    @ObservationIgnored private var doc: [JSON] = []
    @ObservationIgnored private var ask: LiveAsk?
    @ObservationIgnored private var active = 0

    public init(site: SiteModel) {
        self.site = site
    }

    public var canManage: Bool { site.canConfigure && site.hasPassthrough }

    public func activate() {
        active += 1
        if ask == nil {
            ask = LiveAsk(site: site, want: { [weak self] in
                guard let self, self.active > 0, self.canManage, !self.oldBox else { return nil }
                return "push-history"
            }, ask: { [weak self] in
                try await self?.loadHistory()
                try await self?.loadRules()
            })
        }
        ask?.evaluate()
    }

    public func deactivate() {
        active = max(0, active - 1)
        ask?.evaluate()
    }

    private func apply(_ wire: JSON?) {
        guard let events = wire?["events"]?.array else { return }
        doc = events.filter { $0["type"]?.string != nil && $0["enabled"]?.bool != nil }
        boxEnabled = wire?["enabled"]?.bool == true
        availableKinds = doc.compactMap { $0["type"]?.string }
        var next = [String: Bool]()
        for k in Self.ruleKinds { next[k] = false }
        for r in doc { if let t = r["type"]?.string, next[t] != nil { next[t] = r["enabled"]?.bool == true } }
        rules = next
    }

    func loadRules() async throws {
        do {
            apply(try await site.callBox(.get, "/api/notifications/rules"))
        } catch let e as BoxAPIError where e.code == "E_UNKNOWN_OP" {
            oldBox = true
        }
    }

    func loadHistory() async throws {
        do {
            let wire = try await site.callBox(.get, "/api/notifications/history")
            history = (wire?["events"]?.array ?? []).map { Sent(title: $0["title"]?.string ?? "", atMs: $0["at_ms"]?.number) }
        } catch let e as BoxAPIError where e.code == "E_UNKNOWN_OP" {
            oldBox = true
        }
    }

    /// One PUT for the whole set, so one ceremony. Kinds the box's document
    /// does not carry are not sent: an older box must not meet a kind it
    /// would refuse by name.
    @discardableResult
    public func save(_ next: [String: Bool]) async -> Bool {
        guard busy == .none else { return false }
        busy = .saving
        error = nil
        testSent = false
        defer { busy = .none }
        do {
            if doc.isEmpty { try await loadRules() }
            guard !doc.isEmpty else {
                error = "Your box didn't answer. Nothing has changed."
                return false
            }
            let events: [JSON] = doc.compactMap { rule in
                guard let t = rule["type"]?.string, Self.ruleKinds.contains(t), let on = next[t] else { return nil }
                return rule.setting("enabled", .bool(on))
            }
            apply(try await site.callBox(.put, "/api/notifications/rules", body: ["enabled": true, "events": .array(events)]))
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// One real push through the whole pipe, to the phones the box can reach.
    public func sendTest() async {
        guard busy == .none else { return }
        busy = .testing
        error = nil
        testSent = false
        defer { busy = .none }
        do {
            _ = try await site.callBox(.post, "/api/notifications/test")
            testSent = true
        } catch {
            fail(error)
        }
    }

    private func fail(_ err: Error) {
        if let e = err as? BoxAPIError, e.code == "E_UNKNOWN_OP" { oldBox = true }
        error = (err as? BoxAPIError)?.help ?? "That didn't work. Nothing has changed."
    }

    public func when(_ ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        let since = site.nowMs - ms
        if since < 3_600_000 { return "\(max(1, Int((since / 60_000).rounded()))) min ago" }
        if since < 86_400_000 { return "\(Int((since / 3_600_000).rounded())) h ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

/// Ask the box to come back up: a recovery act, owner only, confirmed.
@Observable
@MainActor
public final class RestartModel {
    public enum Stage: Sendable { case idle, confirming, restarting }
    public var stage: Stage = .idle
    public private(set) var error: String?
    @ObservationIgnored private unowned let site: SiteModel

    public init(site: SiteModel) {
        self.site = site
    }

    public var canAsk: Bool { site.heardFromBox && site.canConfigure && site.hasPassthrough }

    public func restart() async {
        guard stage != .restarting else { return }
        error = nil
        stage = .restarting
        do {
            _ = try await site.callBox(.post, "/api/restart")
        } catch {
            stage = .idle
            self.error = (error as? BoxAPIError)?.help ?? "That didn't work. Nothing has changed."
        }
    }
}
