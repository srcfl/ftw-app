import Foundation

/// A local study of pulling a future household-load curve. This value has
/// no transport or planner side effects. Each gesture starts from a copy;
/// every move applies its total displacement to that same copy.
public struct LoadShapeDraft: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public let startMs: Double
        public let endMs: Double
        public let baseWatts: Double
        public private(set) var targetWatts: Double?
        public var watts: Double { targetWatts ?? baseWatts }

        public init(startMs: Double, endMs: Double, baseWatts: Double) {
            self.startMs = startMs
            self.endMs = endMs
            self.baseWatts = baseWatts
        }

        fileprivate mutating func set(_ watts: Double) {
            targetWatts = watts == baseWatts ? nil : watts
        }
    }

    public enum Invalid: Error { case slots, pull }
    public private(set) var slots: [Slot]

    /// Missing intervals stay missing. Input must be in time order and
    /// must contain finite, nonnegative interval means.
    public init(slots: [Slot]) throws {
        var previousEnd = -Double.infinity
        for slot in slots {
            guard slot.startMs.isFinite, slot.endMs.isFinite,
                  slot.endMs > slot.startMs,
                  (slot.endMs - slot.startMs).isFinite,
                  slot.startMs >= previousEnd,
                  slot.baseWatts.isFinite, slot.baseWatts >= 0 else { throw Invalid.slots }
            previousEnd = slot.endMs
        }
        self.slots = slots
    }

    /// Pull nearby interval means by a smooth weight with finite support.
    /// `radiusMs` comes from the visible scale, frozen with the y scale
    /// during the gesture. The current interval and all past ones stay put.
    public func pulling(atMs: Double, byWatts: Double, radiusMs: Double, nowMs: Double) throws -> Self {
        guard atMs.isFinite, byWatts.isFinite, radiusMs.isFinite,
              radiusMs > 0, nowMs.isFinite, atMs >= nowMs else { throw Invalid.pull }
        var result = self
        for i in slots.indices where slots[i].startMs >= nowMs {
            let middle = slots[i].startMs + (slots[i].endMs - slots[i].startMs) / 2
            let distance = abs(middle - atMs) / radiusMs
            guard distance < 1 else { continue }
            let edge = 1 - distance * distance
            let watts = slots[i].watts + byWatts * edge * edge * edge
            guard watts.isFinite else { throw Invalid.pull }
            result.slots[i].set(max(0, watts))
        }
        return result
    }

    /// Only complete future intervals are submitted. A draft may have
    /// stayed open while the box's clock moved into one of its intervals.
    public func changes(nowMs: Double) -> [Slot] {
        guard nowMs.isFinite else { return [] }
        return slots.filter { $0.startMs >= nowMs && $0.targetWatts != nil }
    }

    /// Reset the selected future intervals to this draft's base forecast.
    /// The caller reads the current base from Core after a real reset.
    public func resetting(in range: Range<Double>, nowMs: Double) -> Self {
        guard range.lowerBound.isFinite, range.upperBound.isFinite, nowMs.isFinite else { return self }
        var result = self
        for i in slots.indices where slots[i].startMs >= nowMs && slots[i].startMs < range.upperBound && slots[i].endMs > range.lowerBound {
            result.slots[i].set(slots[i].baseWatts)
        }
        return result
    }
}
