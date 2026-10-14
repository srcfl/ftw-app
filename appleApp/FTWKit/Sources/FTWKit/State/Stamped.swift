import Foundation

/// A value with when it was true and where it came from. Screens branch on
/// whether a value exists, never on whether it is loaded: a value from the
/// cache is drawn in its final place, dated, and replaced when the box
/// speaks.
public struct Stamped<Value: Sendable>: Sendable {
    public typealias Origin = StampOrigin

    public var value: Value
    /// When the box said it, by the phone clock.
    public var asOfMs: Double
    public var origin: Origin

    public init(_ value: Value, asOfMs: Double, origin: Origin) {
        self.value = value
        self.asOfMs = asOfMs
        self.origin = origin
    }

    /// The same value, read back from the disk.
    public var cached: Stamped {
        var s = self
        s.origin = .cache
        return s
    }

    public var fromCache: Bool { origin == .cache }
}

extension Stamped: Equatable where Value: Equatable {
    /// What to show once `next` arrives, or nil when nothing on screen
    /// should change. The same value again changes nothing, unless it is
    /// the box confirming what the cache said: then only its origin and age
    /// move. A copy older than what the box already said never replaces it.
    public func taking(_ next: Stamped) -> Stamped? {
        if next.value == value {
            return origin == .cache && next.origin != .cache ? next : nil
        }
        if origin != .cache, next.asOfMs < asOfMs { return nil }
        return next
    }

    /// `next` on top of what may be shown, by the rule above.
    public static func taking(_ next: Stamped, over shown: Stamped?) -> Stamped? {
        guard let shown else { return next }
        return shown.taking(next)
    }
}

extension Stamped: Codable where Value: Codable {}

/// Where a stamped value came from. One type for every value, so a stamp
/// can move from one value to another.
public enum StampOrigin: String, Codable, Sendable {
    /// Kept on this phone from an earlier launch. True when written, never
    /// live.
    case cache
    /// From the box's own session, over the relay or WebRTC.
    case relay
    /// From FTW Cloud, signed by the box.
    case cloud
}
