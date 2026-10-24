import CoreGraphics
import Foundation

/// What a finger on a chart means, decided before the chart moves. A touch
/// that lifts before it has moved 6 pt and before 150 ms is a tap: it opens
/// the chart and never moves the scrub, the hero or the haptics. Until one
/// of the two comes, the scrub waits; a second finger is a span at once.
public struct TouchIntent: Equatable, Sendable {
    /// How far a finger moves before it scrubs.
    public static let slop: CGFloat = 6
    /// How long a finger rests before it scrubs.
    public static let holdMs: Double = 150

    public enum State: Equatable, Sendable {
        /// Down, not yet a scrub: nothing moves.
        case waiting
        case scrub
        /// Lifted while waiting.
        case tap
    }

    public let start: CGPoint
    public let startMs: Double
    public private(set) var state: State = .waiting
    /// How far the finger got from where it came down, the most so far.
    public private(set) var travel: CGFloat = 0

    public init(at start: CGPoint, ms: Double) {
        self.start = start
        startMs = ms
    }

    /// The finger is at `p`, with `fingers` down.
    @discardableResult
    public mutating func moved(to p: CGPoint, atMs ms: Double, fingers: Int = 1) -> State {
        travel = max(travel, hypot(p.x - start.x, p.y - start.y))
        if state == .waiting, fingers >= 2 || travel >= Self.slop || ms - startMs >= Self.holdMs { state = .scrub }
        return state
    }

    /// No event came, and the finger is still down at `ms`.
    @discardableResult
    public mutating func held(atMs ms: Double) -> State {
        if state == .waiting, ms - startMs >= Self.holdMs { state = .scrub }
        return state
    }

    /// Every finger lifted: a tap when the scrub never started.
    @discardableResult
    public mutating func lifted() -> State {
        if state == .waiting { state = .tap }
        return state
    }
}

/// The system's back swipe starts at the screen's leading edge. A chart,
/// the dial and the style scale take no touch that starts within 20 pt of
/// it, so the swipe goes back instead of scrubbing. A finger that starts
/// further in and slides past the end still has the first slot, clamped.
public enum EdgeRule {
    public static let edge: CGFloat = 20

    /// How much of a view whose leading side sits `minX` from the screen's
    /// leading edge leaves its touches to the system.
    public static func inset(minX: CGFloat) -> CGFloat {
        guard minX.isFinite else { return 0 }
        return max(0, edge - minX)
    }
}

/// A finger on the plan dial's ring, inside the plan's scroll. The ring
/// scrubs on a move along it, or after the finger rests 0.1 s; a move that
/// is mostly up or down, or across the ring, is the page's, and it scrolls.
public enum RingIntent {
    public static let holdMs: Double = 100

    public enum Decision: Equatable, Sendable {
        case scrub
        /// The page's: this touch never scrubs.
        case pass
    }

    /// `start` and `now` are the finger's points, `centre` the ring's
    /// centre, all in one space; `heldMs` the time since it came down. Nil
    /// while it is too soon to tell.
    public static func decide(start: CGPoint, now: CGPoint, centre: CGPoint, heldMs: Double) -> Decision? {
        let dx = now.x - start.x, dy = now.y - start.y
        let travel = hypot(dx, dy)
        // A finger that rested scrubs, wherever it goes next.
        if heldMs >= holdMs { return .scrub }
        guard travel >= TouchIntent.slop else { return nil }
        let rx = start.x - centre.x, ry = start.y - centre.y
        let r = hypot(rx, ry)
        guard r > 0 else { return .pass }
        // Along the ring is across the radius.
        let along = abs((dx * -ry + dy * rx) / r)
        let across = abs((dx * rx + dy * ry) / r)
        return along >= across && abs(dx) >= abs(dy) ? .scrub : .pass
    }
}

/// A finger on the plan's lanes, inside the plan's scroll: the lanes run
/// left to right, so a move that is mostly sideways scrubs, and so does a
/// finger that rests 0.1 s; a move that is mostly up or down is the
/// page's, and it scrolls.
public enum LaneIntent {
    public static func decide(start: CGPoint, now: CGPoint, heldMs: Double) -> RingIntent.Decision? {
        if heldMs >= RingIntent.holdMs { return .scrub }
        let dx = now.x - start.x, dy = now.y - start.y
        guard hypot(dx, dy) >= TouchIntent.slop else { return nil }
        return abs(dx) >= abs(dy) ? .scrub : .pass
    }
}
