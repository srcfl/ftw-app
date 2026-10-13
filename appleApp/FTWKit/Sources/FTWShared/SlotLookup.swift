import Foundation

/// The slot under a finger on a chart of slots sorted by start.
public enum SlotLookup {
    /// The last slot that starts at or before `ms`. In a gap that is the
    /// slot before it, the one a stepped line still draws there. Before the
    /// first slot it is the first, past the last it is the last, so a
    /// finger beyond either edge stays on a slot and its marker never
    /// vanishes. Nil only when there are no slots. One binary search.
    public static func clamped<T>(_ slots: [T], at ms: Double, start: (T) -> Double) -> Int? {
        guard !slots.isEmpty else { return nil }
        var lo = 0, hi = slots.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if start(slots[mid]) <= ms { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }
}
