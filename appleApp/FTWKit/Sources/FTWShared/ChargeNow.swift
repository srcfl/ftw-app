import Foundation

// Charge now outside the app: the Live Activity that reminds the owner that
// Charge now is on and has no time limit, and the Control that shows it and
// turns it on or off. Both say what the box confirmed and nothing more. The
// Live Activity names the state ("Charge now on since 14:02"), not power: a
// hold can be on while the car draws nothing, and a phone with its app
// asleep has no reading to show. Once the phone can no longer vouch for it,
// the Live Activity says when the box last confirmed it and stops counting.

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

        /// After this the phone can no longer vouch that Charge now is still
        /// on: the car may have been unplugged, or someone went back to the
        /// plan from another phone.
        public var staleDate: Date { Date(timeIntervalSince1970: (confirmedAtMs + ChargeNowActivity.vouchMs) / 1000) }

        public func isStale(atMs nowMs: Double) -> Bool { nowMs >= confirmedAtMs + ChargeNowActivity.vouchMs }
    }

    /// How long one confirmation is shown as current. The app confirms it
    /// again on every read of the chargers and whenever it comes to the
    /// front; until the box can push to the Live Activity (M7), nothing
    /// confirms it while the app sleeps.
    public static let vouchMs: Double = 15 * 60_000

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

    // MARK: What it shows

    /// The Live Activity at one moment. Current: the state the box confirmed
    /// and a timer from its start. Stale: when the box last confirmed it,
    /// the timer stopped there, and everything dimmed.
    public struct Face: Equatable, Sendable {
        public enum Timer: Equatable, Sendable {
            /// Counts up from the start.
            case running(from: Date)
            /// Stopped at the last confirmation.
            case stopped(from: Date, at: Date)
        }

        public var headline: String
        public var subtitle: String
        public var timer: Timer
        public var dimmed: Bool
    }

    public static func face(_ state: State, stale: Bool, zone: TimeZone) -> Face {
        if stale {
            return Face(
                headline: confirmed(state, zone: zone),
                subtitle: ChargeNowWord.mayHaveChanged.text,
                timer: .stopped(from: state.startedAt, at: state.confirmedAt),
                dimmed: true
            )
        }
        return Face(headline: since(state, zone: zone), subtitle: noTimeLimit, timer: .running(from: state.startedAt), dimmed: false)
    }

    // MARK: Words

    public static var title: String { ChargeNowWord.chargeNow.text }
    public static var summary: String { ChargeNowWord.summary.text }
    public static var backToPlan: String { ChargeNowWord.backToPlan.text }
    public static var noTimeLimit: String { ChargeNowWord.noTimeLimit.text }
    /// For a command the app cannot run yet: not paired, or no home open.
    public static var openAndRetry: String { ChargeNowWord.openAndRetry.text }

    /// "Charge now on since 14:02", on the household's clock.
    public static func since(_ state: State, zone: TimeZone) -> String {
        ChargeNowWord.since.format(clock(state.startedAtMs, zone: zone))
    }

    /// Once stale: when the box last confirmed it.
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

/// What the Charge now Control shows, from the car record the app left in
/// the App Group: on or off as the box last confirmed it, and unknown once
/// that is too old to vouch for. It never shows more than the record says.
public struct ChargeNowControlState: Equatable, Sendable {
    public enum Known: Equatable, Sendable {
        case on, off, noCar, unknown
    }

    public var known: Known
    /// The charger the Control acts on, when the record names one.
    public var loadpointID: String?

    public init(known: Known, loadpointID: String? = nil) {
        self.known = known
        self.loadpointID = loadpointID
    }

    public var isOn: Bool { known == .on }

    /// The line under "Charge now".
    public var label: String {
        switch known {
        case .on: return ChargeNowWord.on.text
        case .off: return ChargeNowWord.off.text
        case .noCar: return ChargeNowWord.noCar.text
        case .unknown: return ChargeNowWord.unknown.text
        }
    }

    /// The car with a cable, else the first; its hold as the box confirmed
    /// it, if the record is no older than a Live Activity would vouch for.
    public static func from(_ read: CacheRead<CarEntry>?, nowMs: Double) -> ChargeNowControlState {
        guard let read else { return ChargeNowControlState(known: .unknown) }
        let cars = read.value.cars
        guard let car = cars.first(where: \.pluggedIn) ?? cars.first else { return ChargeNowControlState(known: .noCar) }
        guard read.srcState == .live, read.ageMs(nowMs: nowMs) <= ChargeNowActivity.vouchMs, let holding = car.holding else {
            return ChargeNowControlState(known: .unknown, loadpointID: car.loadpointID)
        }
        if holding { return ChargeNowControlState(known: .on, loadpointID: car.loadpointID) }
        return ChargeNowControlState(known: car.pluggedIn ? .off : .noCar, loadpointID: car.loadpointID)
    }

    public static let kind = "energy.ftw.charge-now"
}

/// Every sentence the Control and the Live Activity show. The English is
/// the key; the Swedish lives in `Resources/sv.lproj`, and a test checks
/// each one has it.
enum ChargeNowWord: String, CaseIterable {
    case chargeNow = "Charge now"
    case summary = "Starts charging the car at once, until you go back to the plan."
    case backToPlan = "Back to the plan"
    case noTimeLimit = "No time limit"
    case since = "Charge now on since %@"
    case confirmed = "Last confirmed %@ · open FTW"
    case mayHaveChanged = "It may have changed since."
    case on = "On"
    case off = "Off"
    case noCar = "No car plugged in"
    case unknown = "Open FTW to check"
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

    /// The site, or "demo" for the simulated home. Its button carries this
    /// too, so it can never act on another home.
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
