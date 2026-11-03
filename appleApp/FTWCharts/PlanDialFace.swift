import FTWShared
import SwiftUI
import WidgetKit

/// The plan dial, drawn from a `PlanDial`. The phone's plan view, its dial
/// widget, the watch app and the watch's complication all draw this one
/// face, so the four never differ.
///
/// From the outside in: the rim, a hairline with a 2° gap at the top where
/// the half day ends and begins, and the sun's arc on it from the box's
/// forecast, dashed because it is a guess; the whole hours just outside it,
/// as on a clock, the ones gone by fainter; a tick per quarter from now on,
/// as long as the battery's planned power, cyan where it stores, gold where
/// it gives power (as on Now's strip under it), a faint stub where it
/// waits; the car's dotted arc with its goal. The hours gone by have no
/// ticks. The hand is drawn apart (`PlanDialHand`), so a finger on the
/// phone moves it without redrawing the face.
///
/// The pass a tap chose (`lit`) has its ticks at full strength; the rest
/// stay a ghost.
///
/// Every mark is a still path filled once. Nothing glows: a plan is intent,
/// not a reading, so in full colour every hue is a ghost at `Theme.plan`,
/// as on Now's strip. A tinted or clear face is one colour already.
struct PlanDialFace: View, Equatable {
    enum Size: Equatable {
        /// The phone's plan view and the watch app: rim, hours, and the
        /// car's goal where the dial is large enough.
        case app
        /// A widget or a complication: the marks alone.
        case small
    }

    let dial: PlanDial
    /// The plan is old or the box could not plan: every tick in ink3.
    var grey = false
    var size: Size = .app
    /// The time of the pass a tap chose, drawn at full strength.
    var lit: ClosedRange<Double>?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode

    nonisolated static func == (a: Self, b: Self) -> Bool { a.dial == b.dial && a.grey == b.grey && a.size == b.size && a.lit == b.lit }

    var body: some View {
        GeometryReader { geo in
            let g = DialGeometry(side: min(geo.size.width, geo.size.height), size: size)
            let plan = renderingMode == .fullColor ? Theme.plan(contrast) : 1
            let sunPlan = renderingMode == .fullColor ? Theme.planSun(contrast) : 1
            ZStack {
                if size == .app {
                    rim(g).stroke(Theme.ink.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, lineCap: .butt, lineJoin: .round))
                    HourLabels(g: g, dial: dial)
                }
                // The sun is the box's forecast, a guess: dashed, where the
                // prices it plans on are drawn solid.
                sun(g).stroke(grey ? Theme.ink3 : Theme.solar.opacity(sunPlan), style: StrokeStyle(lineWidth: g.sunWidth, lineCap: .butt, lineJoin: .round, dash: g.sunDash))
                stubs(g).fill(grey ? Theme.oldPlan : Theme.ink3.opacity(0.6))
                ticks(g, .gives, lit: false).fill(grey ? Theme.oldPlan : Theme.gives.opacity(lit == nil ? plan : plan * 0.6))
                ticks(g, .stores, lit: false).fill(grey ? Theme.oldPlan : Theme.stores.opacity(lit == nil ? plan : plan * 0.6))
                    .widgetAccentable()
                if !grey, lit != nil {
                    ticks(g, .gives, lit: true).fill(Theme.gives)
                    ticks(g, .stores, lit: true).fill(Theme.stores)
                }
                carDots(g).fill(grey ? Theme.ink3 : Theme.car.opacity(plan))
                    .widgetAccentable()
                // The goal sits inside the car's arc. On a watch that is
                // where the hand's time and price are, so it shows only on
                // a dial as large as the phone's.
                if size == .app, g.side >= 200 { CarGoals(g: g, dial: dial, grey: grey) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    // MARK: Paths

    /// The rim, round from just past the seam to just before it.
    private func rim(_ g: DialGeometry) -> Path {
        g.arc(from: dial.seam + DialGeometry.gap, to: dial.seam + 2 * .pi - DialGeometry.gap, radius: g.rim)
    }

    /// The sun on the rim, sunrise to sunset as the box forecasts them,
    /// clear of the seam.
    private func sun(_ g: DialGeometry) -> Path {
        var p = Path()
        for span in dial.sunAlong {
            let a = max(span.lowerBound, DialGeometry.gap), b = min(span.upperBound, 2 * .pi - DialGeometry.gap)
            p.addPath(g.arc(from: dial.seam + a, to: dial.seam + b, radius: g.rim))
        }
        return p
    }

    /// One path per battery action, so each fills in one go: as long as
    /// the planned power, never shorter than a stub. `lit` takes the
    /// quarters of the chosen pass, or the rest.
    private func ticks(_ g: DialGeometry, _ action: PlanDial.Battery, lit wanted: Bool) -> Path {
        var p = Path()
        for i in dial.first..<dial.turn where dial.quarters[i].battery == action {
            guard let reach = dial.reach(i) else { continue }
            let mid = dial.quarters[i].startMs + PlanDial.quarterMs / 2
            guard (lit?.contains(mid) ?? false) == wanted else { continue }
            let length = max(g.unit * 1.2, (g.rim - g.inner) * reach)
            p.addPath(g.tick(at: dial.angle(quarter: i), from: g.inner, length: length, width: g.tickWidth))
        }
        return p
    }

    /// Quarters in which the battery waits, or the plan says nothing: a
    /// short stub, so the turn keeps its shape.
    private func stubs(_ g: DialGeometry) -> Path {
        var p = Path()
        for i in dial.first..<dial.turn where dial.reach(i) == nil && i % 2 == 0 {
            p.addPath(g.tick(at: dial.angle(quarter: i), from: g.inner, length: g.unit * 0.6, width: g.tickWidth * 0.8))
        }
        return p
    }

    /// The car's charging: a dotted arc inside the ticks, a dot every
    /// other quarter.
    private func carDots(_ g: DialGeometry) -> Path {
        var p = Path()
        for i in dial.first..<dial.turn where dial.quarters[i].car && i % 2 == 0 {
            let c = g.point(dial.angle(quarter: i), g.carRadius)
            p.addEllipse(in: CGRect(x: c.x - g.dot / 2, y: c.y - g.dot / 2, width: g.dot, height: g.dot))
        }
        return p
    }
}

/// The dial's hand, and the lock-on on the quarter a finger or the Crown
/// chose. Apart from the face, so moving it redraws only this.
struct PlanDialHand: View {
    let dial: PlanDial
    /// The quarter chosen; nil, or now's, points the hand at now.
    var selected: Int?
    var size: PlanDialFace.Size = .app

    var body: some View {
        GeometryReader { geo in
            let g = DialGeometry(side: min(geo.size.width, geo.size.height), size: size)
            ZStack {
                if size == .app, let i = selected, i != dial.nowIndex {
                    lockOn(g, i).fill(Theme.ink)
                }
                // From inside the ticks to just past the rim. A face after
                // now's has none until a finger or the Crown chooses.
                if dial.hasHand(selected: selected) {
                    HandLine(along: along, seam: dial.seam, from: g.inner - g.unit * 1.2, to: g.rim + (size == .app ? 3 : 1))
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: size == .app ? 1.5 : 1.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    /// The hand's place as a distance round the turn from the seam, so a
    /// spring back to now runs back along the day, never across the seam.
    private var along: Double {
        var a = dial.handAngle(selected: selected) - dial.seam
        if a < 0 { a += 2 * .pi }
        return a
    }

    /// The quarter chosen: its tick at full length, in ink, and the lock-on
    /// brackets closing on its outer end.
    private func lockOn(_ g: DialGeometry, _ i: Int) -> Path {
        let a = dial.angle(quarter: i)
        var p = g.tick(at: a, from: g.inner - g.unit * 0.8, length: g.rim - g.inner + g.unit * 0.8, width: g.tickWidth * 1.6)
        p.addPath(LockOn.brackets(around: g.point(a, g.rim - g.unit), half: g.unit * 1.6, arm: g.unit * 0.8)
            .strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)))
        return p
    }

}

/// The hand as a shape whose angle can spring.
private struct HandLine: Shape {
    var along: Double
    let seam: Double
    let from: CGFloat
    let to: CGFloat

    var animatableData: Double {
        get { along }
        set { along = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let a = seam + along
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x + from * CGFloat(sin(a)), y: c.y - from * CGFloat(cos(a))))
        p.addLine(to: CGPoint(x: c.x + to * CGFloat(sin(a)), y: c.y - to * CGFloat(cos(a))))
        return p
    }
}

/// The face and its hand together, for the places a finger never touches:
/// the watch, where the Crown moves the hand, and the widgets.
struct PlanDialView: View {
    let dial: PlanDial
    var selected: Int?
    var grey = false
    var size: PlanDialFace.Size = .app

    var body: some View {
        ZStack {
            PlanDialFace(dial: dial, grey: grey, size: size)
                .equatable()
            PlanDialHand(dial: dial, selected: selected, size: size)
        }
    }
}

/// Where things sit on a dial `side` points across.
struct DialGeometry {
    let side: CGFloat
    let size: PlanDialFace.Size

    /// Half the seam's gap: 1° each side of where +12 h meets now.
    static let gap = Double.pi / 180

    var centre: CGPoint { CGPoint(x: side / 2, y: side / 2) }
    /// The outer edge of the longest tick, and the sun's arc.
    var rim: CGFloat { side / 2 - (size == .app ? 13 : 1.5) }
    /// The hours sit just outside the rim, clear of the sun's arc.
    var labelRadius: CGFloat { side / 2 - 5.5 }
    /// Where every tick starts.
    var inner: CGFloat { rim * (size == .app ? 0.62 : 0.56) }
    /// An eighth of a tick's room: the stub, the hand's overhang and the
    /// car's arc are measured in it.
    var unit: CGFloat { (rim - inner) / 8 }
    var tickWidth: CGFloat { max(0.9, side * (size == .app ? 0.0085 : 0.012)) }
    var carRadius: CGFloat { inner - unit * (size == .app ? 1.6 : 1.4) }
    var dot: CGFloat { max(1.4, side * 0.012) }
    var sunWidth: CGFloat { size == .app ? 2 : max(1.2, side * 0.015) }
    /// The forecast's dash: short enough to read as a guess at any size.
    var sunDash: [CGFloat] { size == .app ? [4, 3] : [max(1.5, side * 0.02), max(1.2, side * 0.016)] }
    /// The hours' and the car goal's mono size.
    var label: CGFloat { max(9, (side * 0.03).rounded()) }

    /// A point `r` from the centre, `a` radians clockwise from the top.
    func point(_ a: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + r * CGFloat(sin(a)), y: centre.y - r * CGFloat(cos(a)))
    }

    /// An arc clockwise from `a` to `b`, as short straight steps.
    func arc(from a: Double, to b: Double, radius r: CGFloat) -> Path {
        var p = Path()
        guard b > a else { return p }
        let steps = max(2, Int((b - a) / (.pi / 180)))
        p.move(to: point(a, r))
        for k in 1...steps { p.addLine(to: point(a + (b - a) * Double(k) / Double(steps), r)) }
        return p
    }

    /// A tick as a thin quad along the radius.
    func tick(at a: Double, from r0: CGFloat, length: CGFloat, width: CGFloat) -> Path {
        let half = Double(width / 2)
        let nx = CGFloat(cos(a)) * CGFloat(half), ny = CGFloat(sin(a)) * CGFloat(half)
        let p0 = point(a, r0), p1 = point(a, r0 + length)
        var p = Path()
        p.move(to: CGPoint(x: p0.x - nx, y: p0.y - ny))
        p.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
        p.addLine(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
        p.addLine(to: CGPoint(x: p0.x + nx, y: p0.y + ny))
        p.closeSubpath()
        return p
    }
}

/// The whole hours of the turn just outside the rim, in the terminal's
/// mono, where a clock has them: "18" straight down. The three, six, nine
/// and twelve o'clock places a step stronger, and the hours gone by a step
/// fainter.
private struct HourLabels: View {
    let g: DialGeometry
    let dial: PlanDial

    var body: some View {
        ForEach(dial.hours, id: \.label) { h in
            let k = h.angle / (.pi / 2)
            let onQuarter = abs(k - k.rounded()) < 0.01
            Text(verbatim: h.label)
                .font(.system(size: g.label, weight: onQuarter ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(h.past ? Theme.ink3.opacity(0.6) : onQuarter ? Theme.ink2 : Theme.ink3)
                .position(g.point(h.angle, g.labelRadius))
        }
    }
}

/// The level each car charges toward, at the end of its dotted arc.
private struct CarGoals: View {
    let g: DialGeometry
    let dial: PlanDial
    let grey: Bool

    var body: some View {
        ForEach(Array(dial.quarters.indices.filter { dial.quarters[$0].carGoalPct != nil }), id: \.self) { i in
            Text(verbatim: "\(Int((dial.quarters[i].carGoalPct ?? 0).rounded()))\u{00A0}%")
                .font(.system(size: g.label * 0.9, weight: .medium, design: .monospaced))
                .foregroundStyle(grey ? Theme.ink3 : Theme.car)
                .fixedSize()
                .position(g.point(dial.angle(quarter: i), g.carRadius - g.label * 1.3))
        }
    }
}
