import Foundation

/// A chart's value axis, from zero or below it to zero or above it. It
/// comes from the data the chart is going to, never from a point in the
/// middle of a spring, and it holds still while data arrives.
public struct YDomain: Equatable, Sendable {
    public var lower: Double
    public var upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    public var span: Double { upper - lower }

    /// The steps a domain may end on: 1, 1.5, 2, 3, 5 or 7.5 times a power
    /// of ten.
    static let steps: [Double] = [1, 1.5, 2, 3, 5, 7.5, 10]

    /// The smallest step at or above `x`.
    public static func nice(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 0 }
        let e = pow(10, (log10(x)).rounded(.down))
        // 0.9999 keeps 300 from becoming 500 through rounding in log10.
        return (steps.first { $0 * e >= x * 0.9999 } ?? 10) * e
    }

    /// The steps a scale is marked in between its ends: round to read, so
    /// 1, 2, 2.5 or 5 times a power of ten, never 1.5 or 7.5.
    static let rungSteps: [Double] = [1, 2, 2.5, 5, 10]

    /// The values a chart marks between its ends: the multiples of the
    /// smallest round step that leaves at most two of them, never zero
    /// (which has its own line) and none within half a step of an end,
    /// where it would crowd the end's own mark. A −2…7.5 kW scale is
    /// marked at 2.5 and 5 kW, a −3…5 kW one at 2.5 kW. A scale under
    /// 10 W is not marked: its rungs would round to the watt.
    public var rungs: [Double] {
        guard span >= 10, span.isFinite else { return [] }
        // A step under `e` leaves at least five marks inside, so the
        // search starts there.
        let e = pow(10, (log10(span / 6)).rounded(.down))
        for m in [1.0, 10] {
            for s in Self.rungSteps {
                let step = s * e * m
                let marks = Self.multiples(of: step, inside: self)
                if marks.count <= 2 { return marks }
            }
        }
        return []
    }

    /// The multiples of `step` at least half a step inside `domain`, zero
    /// left out.
    static func multiples(of step: Double, inside domain: YDomain) -> [Double] {
        let eps = step * 1e-6
        var out = [Double]()
        var v = (domain.lower / step).rounded(.up) * step
        while v < domain.upper - eps {
            let room = min(v - domain.lower, domain.upper - v)
            if room >= step / 2 - eps, abs(v) > eps { out.append(v) }
            v += step
        }
        return out
    }

    /// The domain for data from `low` to `high`. Each side of zero ends on
    /// a nice step at least 10 % past its peak. It grows at once, and
    /// shrinks only when the data fills less than 55 % of it, so the labels
    /// stay put for hours. `floor`, raised to a nice step, is the least a
    /// side with data may reach, and the top when no side has data.
    public static func stable(low: Double, high: Double, previous: YDomain? = nil, floor: Double = 1) -> YDomain {
        let floor = floor > 0 ? nice(floor) : 1
        let up = max(0, high.isFinite ? high : 0)
        let down = max(0, low.isFinite ? -low : 0)
        func side(_ peak: Double, _ before: Double?) -> Double {
            let target = peak > 0 ? max(nice(peak * 1.1), floor) : 0
            guard let before else { return target }
            if target > before { return target }
            if peak < before * 0.55 { return target }
            return before
        }
        var top = side(up, previous.map { max(0, $0.upper) })
        let bottom = side(down, previous.map { max(0, -$0.lower) })
        if top == 0, bottom == 0 { top = floor }
        return YDomain(lower: -bottom, upper: top)
    }
}

/// Values to screen: y grows down from the top of the plot.
public struct YMap: Equatable, Sendable {
    public var domain: YDomain
    public var height: CGFloat

    public init(domain: YDomain, height: CGFloat) {
        self.domain = domain
        self.height = height
    }

    public func y(_ v: Double) -> CGFloat {
        domain.span > 0 ? CGFloat(1 - (v - domain.lower) / domain.span) * height : height
    }

    /// Where zero sits.
    public var baseline: CGFloat { y(0) }
}
