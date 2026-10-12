import Foundation

// "Charging now" outside the app: the Live Activity that reminds the owner
// that Charge now is on and has no time limit. The phone starts it when the
// box confirms Charge now, and ends it when the box confirms that charging
// went back to the plan. It shows the time the box confirmed it, a timer
// from then, and one button. It never shows power: a phone with its app
// asleep has no reading to show, and a figure it cannot vouch for would be
// invented.

/// What the Live Activity holds, and how it moves on each answer from the
/// box. Plain values, so the app, the widget extension and a test all read
/// the same rules.
public enum ChargeNowActivity {
    /// The Live Activity's dynamic state. Two times, both on the phone's
    /// clock: when the box first confirmed Charge now, and when the phone
    /// last saw it still on.
    public struct State: Codable, Hashable, Sendable {
        public var startedAtMs: Double
        public var confirmedAtMs: Double

        public init(startedAtMs: Double, confirmedAtMs: Double) {
            self.startedAtMs = startedAtMs
            self.confirmedAtMs = confirmedAtMs
        }

        public var startedAt: Date { Date(timeIntervalSince1970: startedAtMs / 1000) }
        public var confirmedAt: Date { Date(timeIntervalSince1970: confirmedAtMs / 1000) }

        /// After this the phone can no longer vouch that charging is still
        /// on: the car may have been unplugged, or someone went back to the
        /// plan from another phone. The view then says when it was last
        /// confirmed instead.
        public var staleDate: Date { Date(timeIntervalSince1970: (confirmedAtMs + ChargeNowActivity.vouchMs) / 1000) }
    }

    /// How long one confirmation is shown as current. Until the box can
    /// push to the Live Activity (M7), nothing confirms it while the app
    /// sleeps.
    public static let vouchMs: Double = 60 * 60_000

    /// What the box just said about one charger.
    public enum Event: Equatable, Sendable {
        /// The box confirmed Charge now: its `cmd.result`, or, when the
        /// result never came, a read of the charger after this phone asked.
        case started(atMs: Double)
        /// The box confirmed Back to the plan or Pause.
        case stopped
        /// A read of the charger. `holding` is whether Charge now is on.
        case seen(holding: Bool, atMs: Double)
    }

    public enum Action: Equatable, Sendable {
        case start(State)
        case update(State)
        case end
        case none
    }

    /// The next step for one charger's Live Activity. Only a confirmation
    /// starts one: a read that finds Charge now on without this phone having
    /// asked does not know when it started.
    public static func next(_ current: State?, _ event: Event) -> Action {
        switch (current, event) {
        case (nil, .started(let at)):
            return .start(State(startedAtMs: at, confirmedAtMs: at))
        case (nil, _):
            return .none
        case (let s?, .started(let at)), (let s?, .seen(true, let at)):
            return .update(State(startedAtMs: s.startedAtMs, confirmedAtMs: max(s.confirmedAtMs, at)))
        case (_?, .stopped), (_?, .seen(false, _)):
            return .end
        }
    }

    // MARK: Words

    public static var title: String { ChargeNowWord.chargeNow.text }
    public static var summary: String { ChargeNowWord.summary.text }
    public static var backToPlan: String { ChargeNowWord.backToPlan.text }
    public static var noTimeLimit: String { ChargeNowWord.noTimeLimit.text }
    /// For a command the app cannot run yet: not paired, or no home open.
    public static var openAndRetry: String { ChargeNowWord.openAndRetry.text }

    /// "Charging now since 14:02", on the household's clock.
    public static func since(_ state: State, zone: TimeZone) -> String {
        ChargeNowWord.since.format(clock(state.startedAtMs, zone: zone))
    }

    /// "Since 14:02", for the smallest places.
    public static func sinceShort(_ state: State, zone: TimeZone) -> String {
        ChargeNowWord.sinceShort.format(clock(state.startedAtMs, zone: zone))
    }

    /// After `staleDate`: when the phone last saw it on.
    public static func confirmed(_ state: State, zone: TimeZone) -> String {
        ChargeNowWord.confirmed.format(clock(state.confirmedAtMs, zone: zone))
    }

    static func clock(_ ms: Double, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Every sentence the Control and the Live Activity show. The English is
/// the key; the Swedish lives in `Resources/sv.lproj`, and a test checks
/// each one has it.
enum ChargeNowWord: String, CaseIterable {
    case chargeNow = "Charge now"
    case summary = "Starts charging the car at once, until you go back to the plan."
    case backToPlan = "Back to the plan"
    case noTimeLimit = "No time limit"
    case since = "Charging now since %@"
    case sinceShort = "Since %@"
    case confirmed = "Last confirmed %@ · open FTW"
    case openToCharge = "Open FTW to charge now."
    case openAndRetry = "Open FTW, then try again."

    var text: String { Words.text(rawValue) }

    func format(_ arg: String) -> String {
        String(format: text, arg)
    }
}

#if os(iOS)
import ActivityKit

/// The Live Activity's attributes. One per charger and home; the zone is
/// the household's, so "since 14:02" reads as the box's own page would.
public struct ChargeNowAttributes: ActivityAttributes {
    public typealias ContentState = ChargeNowActivity.State

    /// The site, or "demo" for the simulated home.
    public var home: String
    public var loadpointID: String
    public var zoneID: String

    public init(home: String, loadpointID: String, zone: TimeZone) {
        self.home = home
        self.loadpointID = loadpointID
        zoneID = zone.identifier
    }

    public var zone: TimeZone { TimeZone(identifier: zoneID) ?? .current }
}
#endif
