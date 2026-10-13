import Foundation

/// The rules for a finger on a chart, kept apart from the view so they can
/// be tested. Work happens only when the finger crosses into another slot.
/// A crossing ticks (`.selection`), at most one tick per 40 ms; a landmark
/// (now, the cheapest window's edges, the day's high and low, the car's
/// goal, the ends of a span) gives a light impact every time. The view
/// bumps its haptic triggers from `ticks` and `bumps` in the same update
/// as the index.
public struct ScrubStep: Equatable, Sendable {
    public enum Haptic: Equatable, Sendable {
        case none
        case selection
        case impact
    }

    /// The least time between two ticks: about 25 a second at most.
    public static let floor: Duration = .milliseconds(40)

    public private(set) var index: Int?
    public private(set) var ticks = 0
    public private(set) var bumps = 0
    private var lastHaptic: ContinuousClock.Instant?

    public init() {}

    /// The finger is over slot `next`. Returns what to play, if anything.
    @discardableResult
    public mutating func move(to next: Int, landmark: Bool, at now: ContinuousClock.Instant = .now) -> Haptic {
        guard next != index else { return .none }
        index = next
        if landmark {
            bumps += 1
            lastHaptic = now
            return .impact
        }
        if let last = lastHaptic, now - last < Self.floor { return .none }
        ticks += 1
        lastHaptic = now
        return .selection
    }

    /// The finger lifted. The counters keep counting, so the next touch's
    /// first tick still changes them.
    public mutating func lift() {
        index = nil
    }
}
