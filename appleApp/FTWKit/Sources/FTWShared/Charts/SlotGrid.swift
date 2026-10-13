import Foundation

/// The slots of a chart and where they sit across the plot. A finger's x
/// maps to a slot by arithmetic, clamped to the first and last slot, so a
/// finger past either edge or over a gap still has a slot under it and the
/// marker never vanishes. A gap is a slot with no value: the rule stays on
/// it and the readout says so.
public struct SlotGrid: Equatable, Sendable {
    /// Where slot 0 starts. It may start before `fromMs` when the window
    /// cuts the first slot.
    public var firstMs: Double
    public var stepMs: Double
    public var count: Int
    /// The window the plot's width shows.
    public var fromMs: Double
    public var toMs: Double

    public init(firstMs: Double, stepMs: Double, count: Int, fromMs: Double, toMs: Double) {
        self.firstMs = firstMs
        self.stepMs = stepMs
        self.count = count
        self.fromMs = fromMs
        self.toMs = toMs
    }

    public func startMs(_ i: Int) -> Double { firstMs + Double(i) * stepMs }
    public func endMs(_ i: Int) -> Double { firstMs + Double(i + 1) * stepMs }

    /// The slot that holds `ms`, clamped to the first and last. Nil only
    /// when there are no slots.
    public func index(atMs ms: Double) -> Int? {
        guard count > 0, stepMs > 0 else { return nil }
        let raw = ((ms - firstMs) / stepMs).rounded(.down)
        guard raw.isFinite else { return raw > 0 ? count - 1 : 0 }
        return Int(min(max(raw, 0), Double(count - 1)))
    }

    /// The slot under a finger at `x` on a plot `width` wide, clamped.
    public func index(atX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0 else { return nil }
        return index(atMs: ms(atX: x, width: width))
    }

    /// The moment at `x`, kept inside the window.
    public func ms(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return fromMs }
        return fromMs + Double(min(max(x, 0), width) / width) * (toMs - fromMs)
    }

    public func x(atMs ms: Double, width: CGFloat) -> CGFloat {
        toMs > fromMs ? CGFloat((ms - fromMs) / (toMs - fromMs)) * width : 0
    }

    /// The middle of the part of a slot the window shows.
    public func midX(_ i: Int, width: CGFloat) -> CGFloat {
        x(atMs: (max(startMs(i), fromMs) + min(endMs(i), toMs)) / 2, width: width)
    }

    /// The live curve is 1 Hz with jitter, not a grid: the sample nearest
    /// `t` by one binary search over sorted times, clamped to the first and
    /// last. Nil only when there are none. Whether the nearest is too far
    /// to count (a gap) is the caller's rule.
    public static func nearest(_ times: [Double], to t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == times.count { return times.count - 1 }
        return t - times[lo - 1] <= times[lo] - t ? lo - 1 : lo
    }
}
