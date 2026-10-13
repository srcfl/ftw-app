import CoreGraphics
import Foundation

/// A path as plain values in screen points, so it can be made off the
/// main actor, kept in a `Sendable` geometry and tested. A view draws it
/// with `Path(chartPath.cgPath)`.
public struct ChartPath: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case curve(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public var elements: [Element] = []

    public init(_ elements: [Element] = []) {
        self.elements = elements
    }

    public var isEmpty: Bool { elements.isEmpty }

    public var cgPath: CGPath {
        let p = CGMutablePath()
        for e in elements {
            switch e {
            case let .move(to): p.move(to: to)
            case let .line(to): p.addLine(to: to)
            case let .quad(to, c): p.addQuadCurve(to: to, control: c)
            case let .curve(to, c1, c2): p.addCurve(to: to, control1: c1, control2: c2)
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// Points along the path, each curve cut into `steps` straight pieces.
    /// For tests and hit checks, not for drawing.
    func flattened(steps: Int = 24) -> [CGPoint] {
        var out: [CGPoint] = []
        var at = CGPoint.zero, start = CGPoint.zero
        for e in elements {
            switch e {
            case let .move(to):
                at = to
                start = to
                out.append(to)
            case let .line(to):
                at = to
                out.append(to)
            case let .quad(to, c):
                for k in 1...steps {
                    let s = CGFloat(k) / CGFloat(steps), r = 1 - s
                    out.append(CGPoint(x: r * r * at.x + 2 * r * s * c.x + s * s * to.x, y: r * r * at.y + 2 * r * s * c.y + s * s * to.y))
                }
                at = to
            case let .curve(to, c1, c2):
                for k in 1...steps {
                    let s = CGFloat(k) / CGFloat(steps), r = 1 - s
                    let a = r * r * r, b = 3 * r * r * s, c = 3 * r * s * s, d = s * s * s
                    out.append(CGPoint(x: a * at.x + b * c1.x + c * c2.x + d * to.x, y: a * at.y + b * c1.y + c * c2.y + d * to.y))
                }
                at = to
            case .close:
                at = start
                out.append(start)
            }
        }
        return out
    }
}

// MARK: - Lines

extension ChartPath {
    /// One run as a smooth curve that invents nothing: Steffen's monotone
    /// cubic. Between two points the curve stays between their values, an
    /// extreme sits only on a data point, and a flat stretch on either side
    /// of a step gives the step level shoulders. `pts` run left to right;
    /// a gap is two runs, so it stays a break. A lone point is a line of no
    /// length, which a round cap draws as a dot.
    public mutating func addMonotone(_ pts: [CGPoint]) {
        guard let first = pts.first else { return }
        elements.append(.move(first))
        let n = pts.count
        guard n > 1 else {
            elements.append(.line(first))
            return
        }
        elements.reserveCapacity(elements.count + n)
        var h = [CGFloat](repeating: 0, count: n - 1), s = h
        for i in 0..<(n - 1) {
            h[i] = max(pts[i + 1].x - pts[i].x, 1e-6)
            s[i] = (pts[i + 1].y - pts[i].y) / h[i]
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = s[0]
        m[n - 1] = s[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                let p = (s[i - 1] * h[i] + s[i] * h[i - 1]) / (h[i - 1] + h[i])
                let sign: CGFloat = (s[i - 1] > 0 ? 1 : s[i - 1] < 0 ? -1 : 0) + (s[i] > 0 ? 1 : s[i] < 0 ? -1 : 0)
                m[i] = sign * min(abs(s[i - 1]), abs(s[i]), 0.5 * abs(p))
            }
        }
        for i in 0..<(n - 1) {
            let third = h[i] / 3
            elements.append(.curve(
                pts[i + 1],
                control1: CGPoint(x: pts[i].x + third, y: pts[i].y + m[i] * third),
                control2: CGPoint(x: pts[i + 1].x - third, y: pts[i + 1].y - m[i + 1] * third)
            ))
        }
    }

    /// The same curve closed on `baseline`, so the body and the line always
    /// agree. A signed series fills it twice, clipped above and below zero.
    public mutating func addMonotoneBody(_ pts: [CGPoint], baseline: CGFloat) {
        guard pts.count > 1, let first = pts.first, let last = pts.last else { return }
        addMonotone(pts)
        elements.append(.line(CGPoint(x: last.x, y: baseline)))
        elements.append(.line(CGPoint(x: first.x, y: baseline)))
        elements.append(.close)
    }

    /// A polyline with its corners rounded. A corner's arc is cut no
    /// deeper than `maxShift` from its point, starts no further out than
    /// half of either segment, and is no rounder than a circle of
    /// `maxRadius`. The arc stays inside the corner, so it can trim an
    /// extreme but never add one or go past one.
    public mutating func addRoundedPolyline(_ pts: [CGPoint], maxRadius: CGFloat = 5, maxShift: CGFloat = 0.5) {
        guard let first = pts.first else { return }
        elements.append(.move(first))
        let n = pts.count
        guard n > 1 else { return }
        elements.reserveCapacity(elements.count + 2 * n)
        if n > 2 {
            for i in 1..<(n - 1) {
                let p = pts[i - 1], v = pts[i], q = pts[i + 1]
                let ax = p.x - v.x, ay = p.y - v.y, bx = q.x - v.x, by = q.y - v.y
                let la = (ax * ax + ay * ay).squareRoot(), lb = (bx * bx + by * by).squareRoot()
                guard la > 0, lb > 0 else {
                    elements.append(.line(v))
                    continue
                }
                // θ is the angle inside the corner; the line turns by π − θ.
                let cosInside = min(max((ax * bx + ay * by) / (la * lb), -1), 1)
                let sinHalfTurn = ((1 + cosInside) / 2).squareRoot()
                let cosHalfTurn = ((1 - cosInside) / 2).squareRoot()
                guard sinHalfTurn > 1e-6 else {
                    elements.append(.line(v))
                    continue
                }
                // A quad with its control on the corner passes the corner
                // at t·sin(turn/2)/2: that sets the shift cap.
                var t = min(la / 2, lb / 2, 2 * maxShift / sinHalfTurn)
                if cosHalfTurn > 1e-9 { t = min(t, maxRadius * sinHalfTurn / cosHalfTurn) }
                guard t > 1e-6 else {
                    elements.append(.line(v))
                    continue
                }
                elements.append(.line(CGPoint(x: v.x + ax / la * t, y: v.y + ay / la * t)))
                elements.append(.quad(CGPoint(x: v.x + bx / lb * t, y: v.y + by / lb * t), control: v))
            }
        }
        elements.append(.line(pts[n - 1]))
    }

    /// A value per slot, constant across it (prices, the plan), as steps
    /// with rounded corners. A corner's radius is at most `radius`, half
    /// a slot and half the rise, so a step still reads as a step and no
    /// part of the line sits between two slots' values except the riser.
    /// A gap between slots breaks the line.
    public mutating func addRoundedSteps(_ steps: [Step], radius: CGFloat = 3) {
        var drawing = false
        for (i, s) in steps.enumerated() {
            if !drawing {
                elements.append(.move(CGPoint(x: s.x0, y: s.y)))
                drawing = true
            }
            let next = i + 1 < steps.count ? steps[i + 1] : nil
            guard let next, next.x0 - s.x1 <= 0.5 else {
                elements.append(.line(CGPoint(x: s.x1, y: s.y)))
                drawing = false
                continue
            }
            let rise = next.y - s.y
            let r = min(radius, (s.x1 - s.x0) / 2, (next.x1 - next.x0) / 2, abs(rise) / 2)
            guard r > 0 else {
                elements.append(.line(CGPoint(x: s.x1, y: s.y)))
                continue
            }
            let dir: CGFloat = rise > 0 ? 1 : -1
            elements.append(.line(CGPoint(x: s.x1 - r, y: s.y)))
            elements.append(.quad(CGPoint(x: s.x1, y: s.y + dir * r), control: CGPoint(x: s.x1, y: s.y)))
            elements.append(.line(CGPoint(x: s.x1, y: next.y - dir * r)))
            elements.append(.quad(CGPoint(x: s.x1 + r, y: next.y), control: CGPoint(x: s.x1, y: next.y)))
        }
    }

    /// One slot of a stepped line, in screen points.
    public struct Step: Equatable, Sendable {
        public var x0: CGFloat
        public var x1: CGFloat
        public var y: CGFloat

        public init(x0: CGFloat, x1: CGFloat, y: CGFloat) {
            self.x0 = x0
            self.x1 = x1
            self.y = y
        }
    }
}

// MARK: - Builders

public enum ChartPaths {
    public static func monotone(_ pts: [CGPoint]) -> ChartPath {
        var p = ChartPath()
        p.addMonotone(pts)
        return p
    }

    public static func roundedPolyline(_ pts: [CGPoint], maxRadius: CGFloat = 5, maxShift: CGFloat = 0.5) -> ChartPath {
        var p = ChartPath()
        p.addRoundedPolyline(pts, maxRadius: maxRadius, maxShift: maxShift)
        return p
    }

    public static func roundedSteps(_ steps: [ChartPath.Step], radius: CGFloat = 3) -> ChartPath {
        var p = ChartPath()
        p.addRoundedSteps(steps, radius: radius)
        return p
    }

    /// The live trace: simplified, then rounded, with half of the
    /// 0.5 pt budget for each step, so no sample ends up more than 0.5 pt
    /// from the line drawn through it.
    public static func trace(_ pts: [CGPoint], maxRadius: CGFloat = 5) -> ChartPath {
        roundedPolyline(simplify(pts, epsilon: 0.25), maxRadius: maxRadius, maxShift: 0.25)
    }

    /// Ramer–Douglas–Peucker: drops every point that lies within `epsilon`
    /// of the line kept through its neighbours. Every point of `pts` stays
    /// within `epsilon` of the result, and the ends are kept.
    public static func simplify(_ pts: [CGPoint], epsilon: CGFloat = 0.5) -> [CGPoint] {
        let n = pts.count
        guard n > 2 else { return pts }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        let e2 = epsilon * epsilon
        var stack = [(0, n - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let pa = pts[a], dx = pts[b].x - pa.x, dy = pts[b].y - pa.y
            let len2 = dx * dx + dy * dy
            var worst: CGFloat = -1, at = a
            for i in (a + 1)..<b {
                let p = pts[i]
                var t: CGFloat = 0
                if len2 > 0 {
                    t = ((p.x - pa.x) * dx + (p.y - pa.y) * dy) / len2
                    t = t < 0 ? 0 : t > 1 ? 1 : t
                }
                let ex = pa.x + t * dx - p.x, ey = pa.y + t * dy - p.y
                let d = ex * ex + ey * ey
                if d > worst {
                    worst = d
                    at = i
                }
            }
            if worst > e2 {
                keep[at] = true
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n where keep[i] { out.append(pts[i]) }
        return out
    }

    /// The square of the distance from `p` to the segment `a`–`b`.
    static func distance2(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t: CGFloat = 0
        if len2 > 0 { t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1) }
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return x * x + y * y
    }

    /// Slots with equal values merged into one shape each, from the
    /// baseline to the value, with every edge on a device pixel and a gap of
    /// `gapPx` device pixels after each shape, so neighbours never blur into
    /// one another or leave a seam inside a run. A slot with no value or a
    /// zero value draws nothing.
    public static func runs(_ values: [Double?], grid: SlotGrid, width: CGFloat, map: YMap, scale: CGFloat, maxRadius: CGFloat, gapPx: CGFloat = 1) -> [BarRun] {
        let scale = max(scale, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let base = snap(map.baseline)
        var out: [BarRun] = []
        var i = 0
        let n = min(values.count, grid.count)
        while i < n {
            guard let v = values[i], v != 0 else {
                i += 1
                continue
            }
            var j = i + 1
            while j < n, values[j] == v { j += 1 }
            let x0 = snap(max(0, grid.x(atMs: grid.startMs(i), width: width)))
            let x1 = snap(min(width, grid.x(atMs: grid.endMs(j - 1), width: width))) - gapPx / scale
            let y = snap(map.y(v))
            let rect = CGRect(x: x0, y: min(y, base), width: x1 - x0, height: abs(y - base))
            if rect.width > 0, rect.height > 0 {
                out.append(BarRun(first: i, count: j - i, value: v, rect: rect, radius: min(maxRadius, rect.width / 2, rect.height)))
            }
            i = j
        }
        return out
    }
}

/// Equal neighbouring slots drawn as one shape.
public struct BarRun: Equatable, Sendable {
    public var first: Int
    public var count: Int
    public var value: Double
    /// Snapped to device pixels, the gap already taken off its right side.
    public var rect: CGRect
    /// For the corners away from the baseline.
    public var radius: CGFloat

    public init(first: Int, count: Int, value: Double, rect: CGRect, radius: CGFloat) {
        self.first = first
        self.count = count
        self.value = value
        self.rect = rect
        self.radius = radius
    }
}
