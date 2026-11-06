import FTWShared
import SwiftUI
import WidgetKit

/// The plan dial, drawn from a `PlanDial`. The phone's plan view, its dial
/// widget, the watch app and the watch's complication all draw this one
/// face, so the four never differ.
///
/// From the outside in: the rim, a hairline with a 2° gap at the seam where
/// the twelve hours end and begin; the sun as an area hanging in from it,
/// as deep as the box's forecast expects the panels to make, a ghost with a
/// dashed edge because it is a guess (Fredrik, 3 Nov 2026: the forecast is
/// an area, as the rest is); the whole hours just outside the rim, as on a
/// clock; a tick per quarter, as long as the battery's planned power, cyan
/// where it charges, gold where it discharges (as on Now's strip under it),
/// with its outer end in the grid's magenta as far as the home sells what
/// the battery gives (Anders, 4 Nov 2026), a faint stub where it waits; the
/// car's dotted arc with its goal. It
/// draws the quarters of the dial's `window`, so a face wound on shows the
/// hours after. The hand is drawn apart (`PlanDialHand`), so a finger on
/// the phone moves it without redrawing the face.
///
/// The pass a tap chose (`lit`) has its ticks at full strength; the rest
/// stay a ghost.
///
/// On a clock the end of the twelve hours sits just behind the hand, where
/// the eye looks for what has just been: at 23:30 tomorrow's sun read as
/// sun that had just set (xorath, 6 Nov 2026). So the marks fade out over
/// the turn's last three hours, sharp at the hand, and a sun on the next
/// day says so on the rim.
///
/// Every mark is a still path filled once. Nothing glows but the sun's
/// area in the dark, held still: a plan is intent, not a reading, so in
/// full colour every hue is a ghost at `Theme.plan`, as on Now's strip. A
/// tinted or clear face is one colour already.
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
                    if !grey, g.side >= 200 { SunDay(g: g, dial: dial, plan: sunPlan) }
                }
                marks(g, plan: plan, sunPlan: sunPlan)
                    .mask(TurnFade(dial: dial, on: size == .app))
                // A pass someone chose stands at full strength wherever it
                // falls on the turn.
                if !grey, lit != nil {
                    ticks(g, .gives, lit: true).fill(Theme.gives)
                    ticks(g, .gives, lit: true, sold: true).fill(Theme.grid)
                    ticks(g, .stores, lit: true).fill(Theme.stores)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }

    /// What the plan and the forecast say, all of it fading together.
    private func marks(_ g: DialGeometry, plan: Double, sunPlan: Double) -> some View {
        ZStack {
            // The sun is the box's forecast, a guess: a ghost with a
            // dashed edge. Too small for an area, a widget keeps the
            // dashed arc.
            if size == .app {
                SunArea(g: g, dial: dial, grey: grey, plan: sunPlan)
            } else {
                sun(g).stroke(grey ? Theme.ink3 : Theme.solar.opacity(sunPlan), style: StrokeStyle(lineWidth: g.sunWidth, lineCap: .butt, lineJoin: .round, dash: g.sunDash))
            }
            stubs(g).fill(grey ? Theme.oldPlan : Theme.ink3.opacity(0.6))
            ticks(g, .gives, lit: false).fill(grey ? Theme.oldPlan : Theme.gives.opacity(lit == nil ? plan : plan * 0.6))
            ticks(g, .gives, lit: false, sold: true).fill(grey ? Theme.oldPlan : Theme.grid.opacity(lit == nil ? plan : plan * 0.6))
            ticks(g, .stores, lit: false).fill(grey ? Theme.oldPlan : Theme.stores.opacity(lit == nil ? plan : plan * 0.6))
                .widgetAccentable()
            carDots(g).fill(grey ? Theme.ink3 : Theme.car.opacity(plan))
                .widgetAccentable()
            // The goal sits inside the car's arc. On a watch that is
            // where the hand's time and price are, so it shows only on
            // a dial as large as the phone's.
            if size == .app, g.side >= 200 { CarGoals(g: g, dial: dial, grey: grey) }
        }
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
    /// quarters of the chosen pass, or the rest. A tick whose power the
    /// home sells in part is two pieces end to end: what the home keeps
    /// from the inside, then `sold`, what leaves it, out to the tick's end.
    private func ticks(_ g: DialGeometry, _ action: PlanDial.Battery, lit wanted: Bool, sold: Bool = false) -> Path {
        var p = Path()
        for i in dial.window where dial.quarters[i].battery == action {
            guard let reach = dial.reach(i) else { continue }
            let mid = dial.quarters[i].startMs + PlanDial.quarterMs / 2
            guard (lit?.contains(mid) ?? false) == wanted else { continue }
            let length = max(g.unit * 1.2, (g.rim - g.inner) * reach)
            let kept = length * CGFloat(1 - dial.soldShare(i))
            let (from, piece) = sold ? (g.inner + kept, length - kept) : (g.inner, kept)
            guard piece > 0 else { continue }
            p.addPath(g.tick(at: dial.angle(quarter: i), from: from, length: piece, width: g.tickWidth))
        }
        return p
    }

    /// Quarters in which the battery waits, or the plan says nothing: a
    /// short stub, so the turn keeps its shape.
    private func stubs(_ g: DialGeometry) -> Path {
        var p = Path()
        for i in dial.window where dial.reach(i) == nil && i % 2 == 0 {
            p.addPath(g.tick(at: dial.angle(quarter: i), from: g.inner, length: g.unit * 0.6, width: g.tickWidth * 0.8))
        }
        return p
    }

    /// The car's charging: a dotted arc inside the ticks, a dot every
    /// other quarter.
    private func carDots(_ g: DialGeometry) -> Path {
        var p = Path()
        for i in dial.window where dial.quarters[i].car && i % 2 == 0 {
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
                if size == .app, let i = selected, i > 0 {
                    lockOn(g, i).fill(Theme.ink)
                }
                // From inside the ticks to just past the rim, through the
                // seam's gap while it points at now.
                HandLine(along: along, seam: dial.seam, from: g.inner - g.unit * 1.2, to: g.rim + (size == .app ? 3 : 1))
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: size == .app ? 1.5 : 1.2, lineCap: .round, lineJoin: .round))
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

/// The sun as the forecast's area: from the rim in, as deep as the watts
/// it expects against the most it expects (half the ticks' room at most),
/// from now or sunrise to sunset, smooth, with a dashed edge. In the dark
/// it is warm: a still blur of its own colour under it, never moving, so
/// it never reads as live. Light mode and Reduce Transparency have none.
private struct SunArea: View {
    let g: DialGeometry
    let dial: PlanDial
    let grey: Bool
    /// `Theme.planSun`, or 1 on a tinted face.
    let plan: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let shape = Self.shape(g, dial)
        ZStack {
            if !grey, scheme == .dark, !reduceTransparency, renderingMode == .fullColor {
                shape.area.fill(Theme.solar.opacity(0.3)).blur(radius: max(2, g.side * 0.014))
            }
            shape.area.fill(grey ? Theme.ink3.opacity(0.2) : Theme.solar.opacity(0.2 * plan))
            shape.edge.stroke(grey ? Theme.ink3 : Theme.solar.opacity(plan), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: g.sunDash))
        }
    }

    /// One area and one edge for each run of sun on the face, clear of the
    /// seam.
    static func shape(_ g: DialGeometry, _ dial: PlanDial) -> (area: Path, edge: Path) {
        var area = Path(), edge = Path()
        let depth = (g.rim - g.inner) * 0.5
        let window = dial.window
        var i = window.lowerBound
        while i < window.upperBound {
            guard dial.sunReach(i) != nil else { i += 1; continue }
            var j = i
            while j + 1 < window.upperBound, dial.sunReach(j + 1) != nil { j += 1 }
            let a0 = max(dial.along(max(dial.grid.startMs(i), dial.nowMs)), DialGeometry.gap)
            var a1 = dial.along(dial.grid.endMs(j))
            if a1 <= a0 { a1 = 2 * .pi }
            a1 = min(a1, 2 * .pi - DialGeometry.gap)
            // Sunrise and sunset taper to the rim. Where the sun is already
            // up at now or at the face's start, or still up at its end, the
            // area stops square.
            func at(_ a: Double, _ k: Int) -> CGPoint { g.point(dial.seam + a, g.rim - depth * CGFloat(dial.sunReach(k) ?? 0)) }
            var points = [g.point(dial.seam + a0, g.rim)]
            if i == window.lowerBound { points.append(at(a0, i)) }
            for k in i...j {
                points.append(at(min(max(dial.along(dial.grid.startMs(k) + PlanDial.quarterMs / 2), a0), a1), k))
            }
            if j == window.upperBound - 1 { points.append(at(a1, j)) }
            points.append(g.point(dial.seam + a1, g.rim))
            let profile = smooth(points)
            edge.addPath(profile)
            var run = profile
            // Back along the rim to where it began.
            let steps = max(2, Int((a1 - a0) / (.pi / 180)))
            for s in 1...steps { run.addLine(to: g.point(dial.seam + a1 - (a1 - a0) * Double(s) / Double(steps), g.rim)) }
            run.closeSubpath()
            area.addPath(run)
            i = j + 1
        }
        return (area, edge)
    }

    /// Through the points with no corners: a curve to each midpoint, the
    /// point between as its control.
    private static func smooth(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 3 else {
            p.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        // The first and last legs are straight, so a square end stays
        // square.
        path.addLine(to: p[1])
        for k in 1..<(p.count - 2) {
            let mid = CGPoint(x: (p[k].x + p[k + 1].x) / 2, y: (p[k].y + p[k + 1].y) / 2)
            path.addQuadCurve(to: mid, control: p[k])
        }
        path.addLine(to: p[p.count - 2])
        path.addLine(to: p[p.count - 1])
        return path
    }
}

/// What keeps a mark's strength round the turn: whole from the seam on, down
/// to `PlanDial.turnFadeFloor` over the last `turnFadeShare`, and whole again
/// at the seam. Off, it keeps everything.
private struct TurnFade: View {
    let dial: PlanDial
    let on: Bool

    var body: some View {
        if on {
            let start = Angle.radians(dial.seam - .pi / 2)
            AngularGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1 - PlanDial.turnFadeShare),
                    .init(color: .black.opacity(PlanDial.turnFadeFloor), location: 1),
                ],
                center: .center,
                startAngle: start,
                endAngle: start + .radians(2 * .pi)
            )
        } else {
            Color.black
        }
    }
}

/// "TOMORROW" round the rim, between two hours beside tomorrow's sun, in the
/// sun's colour: the one word that tells it from the sun that has just been.
private struct SunDay: View {
    let g: DialGeometry
    let dial: PlanDial
    let plan: Double

    var body: some View {
        if let angle = dial.sunTomorrowAngle {
            let word = Array(dial.tomorrowWord)
            let size = g.label * 0.8
            // On the lower half the word runs the other way round, or it
            // would stand on its head.
            let lower = angle > .pi / 2 && angle < 3 * .pi / 2
            let pitch = Double(size) * 0.68 / Double(g.labelRadius) * (lower ? -1 : 1)
            ForEach(word.indices, id: \.self) { k in
                let a = angle + (Double(k) - Double(word.count - 1) / 2) * pitch
                Text(String(word[k]))
                    .font(.system(size: size, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.solar.opacity(plan))
                    .rotationEffect(.radians(lower ? a + .pi : a))
                    .position(g.point(a, g.labelRadius))
            }
        }
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
                .foregroundStyle(onQuarter ? Theme.ink2 : Theme.ink3)
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
        ForEach(Array(dial.window.filter { dial.quarters[$0].carGoalPct != nil }), id: \.self) { i in
            Text(verbatim: "\(Int((dial.quarters[i].carGoalPct ?? 0).rounded()))\u{00A0}%")
                .font(.system(size: g.label * 0.9, weight: .medium, design: .monospaced))
                .foregroundStyle(grey ? Theme.ink3 : Theme.car)
                .fixedSize()
                .position(g.point(dial.angle(quarter: i), g.carRadius - g.label * 1.3))
        }
    }
}
