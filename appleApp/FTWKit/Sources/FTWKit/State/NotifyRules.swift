import Foundation
import FTWShared
import Observation

/// Which notifications the box sends: its rules document, GET and PUT
/// /api/notifications/rules, read and written as the web app's settings do.
/// The rules are the box's, one set for the home, so a switch here turns a
/// kind on or off for every owner's phone. Only an owner may change them.
///
/// A write sends every entry the box carries for a kind this phone knows,
/// whole and flipped only on `enabled`: the box replaces a rule wholesale,
/// and a partial entry would wipe the thresholds it seeded. A kind this
/// phone does not know is never sent, and the box keeps it as it was.
@Observable
@MainActor
public final class NotifyRules {
    public enum Phase: Equatable, Sendable {
        /// Not read yet.
        case unknown
        case ready
        /// The box has no rules document: older software.
        case oldBox
    }

    /// The groups the switches stand in, by what a notification is about.
    public enum Group: String, CaseIterable, Sendable {
        case car, home, access
    }

    /// The kinds this phone can name, in the catalogue's order.
    /// `box.unreachable` is the relay's, and no rule gates it.
    public nonisolated static let choices = PushKind.all.filter { $0 != PushKind.boxUnreachable }

    /// The kinds the box's document carries, in the catalogue's order.
    public private(set) var kinds: [String] = []
    /// Whether each kind is on, as the switches show it.
    public private(set) var on: [String: Bool] = [:]
    /// The box's own switch for all of them. Security notices go out
    /// without it.
    public private(set) var boxOn = false
    public private(set) var phase = Phase.unknown
    public private(set) var saving = false
    /// The last write or read failed, with a sentence to show.
    public private(set) var problem: String?

    @ObservationIgnored private unowned let site: SiteModel
    /// The box's entries, whole, as it last answered.
    @ObservationIgnored private var events: [JSON] = []
    /// What the switches asked for since the last write went out.
    @ObservationIgnored private var pending: (on: [String: Bool], boxOn: Bool)?

    public init(site: SiteModel) {
        self.site = site
    }

    /// Only an owner, over a box that serves its own API.
    public var canChange: Bool { site.canConfigure && site.hasPassthrough }

    public func load() async {
        guard canChange, site.session.phase == .streaming else { return }
        do {
            apply(try await site.callBox(.get, "/api/notifications/rules"))
            problem = nil
        } catch let e as BoxAPIError where e.status == 404 || e.code == "E_UNKNOWN_OP" {
            phase = .oldBox
        } catch let e as BoxAPIError {
            problem = e.help
        } catch {
            problem = AppWords.text("Your box didn't answer. Still trying.")
        }
    }

    /// Turn one kind on or off. The switch moves at once, and any write
    /// turns the box's own switch on: an owner who turns a kind on is
    /// asking to hear it.
    public func set(_ kind: String, _ value: Bool) async {
        var next = pending?.on ?? on
        next[kind] = value
        on = next
        boxOn = true
        await write(on: next, boxOn: true)
    }

    /// Turn every notification from the box on or off.
    public func setBoxOn(_ value: Bool) async {
        boxOn = value
        await write(on: pending?.on ?? on, boxOn: value)
    }

    /// One write at a time; switches flipped meanwhile go in the next.
    private func write(on next: [String: Bool], boxOn value: Bool) async {
        pending = (next, value)
        guard !saving else { return }
        saving = true
        defer { saving = false }
        while let want = pending {
            pending = nil
            do {
                let answer = try await site.callBox(.put, "/api/notifications/rules", body: Self.body(events: events, on: want.on, boxOn: want.boxOn))
                apply(answer)
                problem = nil
            } catch {
                // The switches go back to what the box holds.
                pending = nil
                problem = NodeWords.text("Not saved. Nothing changed on your box.")
                apply(.object([("enabled", .bool(boxOnStored)), ("events", .array(events))]))
                return
            }
        }
    }

    /// The box's own switch as it last answered.
    @ObservationIgnored private var boxOnStored = false

    /// The write's body.
    nonisolated static func body(events: [JSON], on: [String: Bool], boxOn: Bool) -> JSON {
        let out = events.compactMap { e -> JSON? in
            guard let type = e["type"]?.string, choices.contains(type), let v = on[type] else { return nil }
            return e.setting("enabled", .bool(v))
        }
        return .object([("enabled", .bool(boxOn)), ("events", .array(out))])
    }

    private func apply(_ doc: JSON?) {
        guard let doc, let list = doc["events"]?.array else { return }
        events = list
        boxOnStored = doc["enabled"]?.bool == true
        let carried = Set(list.compactMap { $0["type"]?.string })
        kinds = Self.choices.filter(carried.contains)
        var held = [String: Bool]()
        for e in list {
            if let type = e["type"]?.string { held[type] = e["enabled"]?.bool == true }
        }
        // A switch flipped while this write was out keeps its place.
        if let pending {
            on = held.merging(pending.on) { _, mine in mine }
            boxOn = pending.boxOn
        } else {
            on = held
            boxOn = boxOnStored
        }
        phase = .ready
    }

    /// What a notification is about.
    public nonisolated static func group(_ kind: String) -> Group {
        if kind.hasPrefix("charging.") || kind == PushKind.carWhich { return .car }
        if [PushKind.updateInstalled, PushKind.driverOffline, PushKind.fuseOverLimit, PushKind.controlNotFollowing].contains(kind) { return .home }
        return .access
    }

    /// What each switch says: the decision to hear it, in the web app's
    /// words. The notification's own words are the catalogue's.
    public nonisolated static func label(_ kind: String) -> String {
        NodeWords.text(labels[kind] ?? kind)
    }

    nonisolated static let labels: [String: String] = [
        PushKind.chargingConnected: "When the car is plugged in",
        PushKind.chargingSessionComplete: "When the car finishes charging",
        PushKind.chargingGoalAtRisk: "If the car may not be ready in time",
        PushKind.chargingInterrupted: "If charging stops before it is done",
        PushKind.carWhich: "When the box asks which car is plugged in",
        PushKind.updateInstalled: "When your box updates itself",
        PushKind.driverOffline: "If a device goes quiet",
        PushKind.fuseOverLimit: "If the house draws more than the fuse allows",
        PushKind.controlNotFollowing: "If a device does not do what FTW asks",
        PushKind.cloudGranted: "When FTW Cloud is turned on",
        PushKind.cloudRevoked: "When FTW Cloud is turned off",
        PushKind.agentAdded: "When an assistant or Sourceful gets access",
        PushKind.agentRequest: "When an assistant asks to change a setting",
        PushKind.agentExpiring: "When an assistant's or Sourceful's access is about to end",
        PushKind.approvalKeySet: "When a phone sets up the key that approves access",
        PushKind.ownerAdded: "When a phone is paired as an owner",
    ]
}
