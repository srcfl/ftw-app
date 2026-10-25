import FTWKit
import SwiftUI

/// The home and what flows through it, as the box's own dashboard lays it
/// out: the sun top left, the battery top right, the grid bottom left, the
/// car bottom right, and the home's own use in the middle of a ring. A node
/// whose partner across the middle is missing moves onto the middle axis
/// (`FlowPlan`). Each node is text on the ground, with no box, and a door to
/// its own view that grows out of it.
///
/// The ring (Ring / Quiet, chosen by Fredrik on 24 October 2026) gives each
/// node the quarter that faces it. Its arc lights from the quarter's middle
/// out, longer with more power (`Flow.ringFill`), in the node's colour, and
/// a soft wave of light runs along it: clockwise for power coming into the
/// home, the other way for power leaving it. Only a reading the box
/// confirmed live glows or moves: a cached or quiet arc is a faint still
/// arc, and a node at rest shows only its quarter's track.
struct FlowDiagram: View {
    let readings: [NodeReading]
    let zoom: Namespace.ID
    /// Charge now, Pause and Back to the plan, held on the car.
    var car: CarActions?

    /// The labels' sizes, as `NodeLabel` scales them, for the room they take.
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .title) private var figureSize: CGFloat = 30
    @ScaledMetric(relativeTo: .footnote) private var wordSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let nodes = readings.map(\.node)
            let width = Self.nodeWidth(geo.size.width)
            let label = RingGeometry.labelHeight(name: nameSize, figure: figureSize, word: wordSize)
            let axis = nodes.contains { [.top, .bottom].contains(FlowPlan.spot($0, among: nodes)) }
            let ring = RingGeometry(size: geo.size, label: label, labelWidth: width, axis: axis)
            ZStack {
                FlowRing(arcs: arcs(nodes: nodes), ring: ring)
                    .accessibilityHidden(true)
                // The labels sit in the corners of a box just tall enough
                // that none of them touches the ring.
                ZStack {
                    ForEach(readings.filter { $0.node != .home }) { r in
                        let spot = FlowPlan.spot(r.node, among: nodes)
                        // The node's place is a fixed frame, so nothing moves
                        // when a word or a figure changes width; the whole
                        // frame takes the finger.
                        door(r) { NodeLabel(reading: r, spot: spot, scale: ring.labelScale).equatable().frame(width: width, alignment: spot.textAlignment) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spot.alignment)
                    }
                }
                .frame(width: geo.size.width, height: ring.box)
                .position(ring.center)
                if let home = readings.first(where: { $0.node == .home }) {
                    door(home) { HubLabel(reading: home, diameter: ring.hub).equatable() }
                        .position(ring.center)
                }
            }
        }
    }

    /// A corner label's width: 38 % of the flow, from 92 pt to 140 pt.
    static func nodeWidth(_ width: CGFloat) -> CGFloat {
        min(140, max(92, width * 0.38))
    }

    private func door<Label: View>(_ r: NodeReading, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: HomeRoute.node(r.node)) { label() }
            .buttonStyle(LockOnPress())
            .modifier(CarMenu(actions: r.node == .car ? car : nil))
            .matchedTransitionSource(id: HomeRoute.node(r.node), in: zoom)
            .accessibilityIdentifier("now.node.\(r.node.rawValue)")
    }

    private func arcs(nodes: [EnergyNode]) -> [FlowRing.Arc] {
        readings.compactMap { r in
            guard r.node != .home else { return nil }
            return FlowRing.Arc(target: Flow.BeamTarget(r), spot: FlowPlan.spot(r.node, among: nodes), color: NodeLook.hue(r))
        }
    }
}

extension FlowPlan.Spot {
    /// Where the node sits in the flow's frame.
    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        case .top: return .top
        case .bottom: return .bottom
        case .center: return .center
        }
    }

    /// How its text lines up in its frame.
    var textAlignment: Alignment { leading ? .leading : (trailing ? .trailing : .center) }
    var horizontal: HorizontalAlignment { leading ? .leading : (trailing ? .trailing : .center) }
}

/// The ring, in one Canvas inside one `TimelineView`. The light runs at the
/// display's rate while an arc is live and Now is on screen in an active
/// app, at 20 frames a second in Low Power Mode, and for a moment after a
/// change so an arc can grow, ignite or cool; otherwise the timeline rests
/// and nothing draws. Under Reduce Motion the light holds still, ignite and
/// decay are instant, and a still chevron on the arc says which way it
/// flows.
private struct FlowRing: View {
    struct Arc: Equatable {
        let target: Flow.BeamTarget
        let spot: FlowPlan.Spot
        let color: Color
    }

    let arcs: [Arc]
    let ring: RingGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var clock = RingClock()
    /// Changes seen, and the last one the arcs have settled after.
    @State private var changes = 0
    @State private var settled = 0

    /// Long enough for an arc to grow (τ 0.4 s) and a glow to cool.
    static let settle: Duration = .milliseconds(2_400)

    var body: some View {
        let lowPower = PowerState.shared.lowPower
        let waving = arcs.contains { $0.target.live && $0.target.flowing }
        let running = onScreen && scenePhase == .active && !reduceMotion && (waving || changes != settled)
        let still = reduceMotion
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 20 : nil, paused: !running)) { tick in
            Canvas(rendersAsynchronously: false) { g, _ in
                #if DEBUG
                let began = ContinuousClock.now
                defer { ChartDraws.flow(ContinuousClock.now - began) }
                #endif
                draw(&g, at: (running ? tick.date : .now).timeIntervalSinceReferenceDate, still: still)
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: arcs.map(\.target)) { changes += 1 }
        .task(id: changes) {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            settled = changes
        }
    }

    private func draw(_ g: inout GraphicsContext, at t: Double, still: Bool) {
        let dark = g.environment.colorScheme == .dark
        let track = Theme.ink.opacity(dark ? 0.13 : 0.09)
        let style = StrokeStyle(lineWidth: ring.thickness, lineCap: .round)
        // Each node's quarter, the track its arc lights.
        for arc in arcs {
            let a = FlowPlan.ringArc(arc.spot, fill: 1)
            g.stroke(path(a.track), with: .color(track), style: style)
        }
        for arc in arcs {
            let f = clock.frame(arc.target, at: t, reduceMotion: still)
            let k = 1 - f.beam.idle
            guard k > 0.01, let lit = FlowPlan.ringArc(arc.spot, fill: f.fill).lit else { continue }
            let p = path(lit)
            if TraceInk.glows(live: f.beam.light > 0.004, in: g) {
                TraceInk.glow(p, color: arc.color, width: ring.thickness, strength: f.beam.light * k, in: g)
            }
            // Light means live: the arc's colour while the box confirms it,
            // ink once it does not, crossing over as the phosphor ignites
            // or cools.
            let color = Self.mix(Theme.ink2.resolve(in: g.environment), arc.color.resolve(in: g.environment), f.beam.light)
            let cap = Double(ring.thickness) / 2 / Double(ring.radius) * 180 / .pi
            // With no glow (light mode, or Reduce Transparency), full-strength
            // colour says live alone: the wave runs shallower and the arc
            // keeps its colour between crests.
            let glows = dark && !g.environment.accessibilityReduceTransparency
            let stops = Self.stops(lit, radius: Double(ring.radius), clockwise: arc.target.towardHome, f.beam, color, k, lead: cap, depth: glows ? 1 : 0.35)
            g.stroke(p, with: .conicGradient(Gradient(stops: stops), center: ring.center, angle: .degrees(lit.lowerBound - cap)), style: style)
            if still, arc.target.flowing { chevron(lit, clockwise: arc.target.towardHome, opacity: f.beam.alpha * k, in: g) }
        }
    }

    /// From `a` at 0 to `b` at 1.
    static func mix(_ a: Color.Resolved, _ b: Color.Resolved, _ k: Double) -> Color.Resolved {
        let t = Float(min(1, max(0, k)))
        func lerp(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return Color.Resolved(red: lerp(a.red, b.red), green: lerp(a.green, b.green), blue: lerp(a.blue, b.blue), opacity: lerp(a.opacity, b.opacity))
    }

    /// An arc of the ring between two angles, clockwise as drawn.
    private func path(_ range: ClosedRange<Double>) -> Path {
        var p = Path()
        p.addArc(center: ring.center, radius: ring.radius, startAngle: .degrees(range.lowerBound), endAngle: .degrees(range.upperBound), clockwise: false)
        return p
    }

    /// The core's brightness along the arc as stops of a conic gradient that
    /// starts `lead` degrees before the arc's first angle, so the round cap
    /// there takes the arc's first colour rather than the gradient's last.
    /// Inside, the stops sit ten to a wavelength along the arc, close enough
    /// that a crest running past them keeps its height within 4 %.
    static func stops(_ lit: ClosedRange<Double>, radius: Double, clockwise: Bool, _ f: Flow.BeamFrame, _ color: Color.Resolved, _ k: Double, lead: Double = 0, depth scale: Double = 1) -> [Gradient.Stop] {
        let span = lit.upperBound - lit.lowerBound
        let perDegree = radius * .pi / 180
        let length = span * perDegree
        func stop(_ deg: Double) -> Gradient.Stop {
            // Points from where the light starts: the arc's first angle when
            // it runs clockwise, its last when it runs back.
            let s = (clockwise ? deg : span - deg) * perDegree
            let b = f.alpha * (1 - f.depth * scale * (1 - Flow.wave(s, phase: f.phase))) * k
            var c = color
            c.opacity *= Float(b)
            return Gradient.Stop(color: Color(c), location: (deg + lead) / 360)
        }
        var head = stop(0)
        head.location = 0
        var out = [head, stop(0)]
        if f.depth * scale > 0.001, length > 1 {
            let step = Flow.wavelength / 10 / perDegree
            var d = step
            while d < span {
                out.append(stop(d))
                d += step
            }
        }
        out.append(stop(span))
        // Past the arc only the end's round cap is drawn; it keeps the
        // end's colour.
        var tail = out[out.count - 1]
        tail.location = 1
        out.append(tail)
        return out
    }

    /// A still chevron at the middle of an arc, pointing the way the light
    /// would run: 6 pt, in ink, as a mark of the interface.
    private func chevron(_ lit: ClosedRange<Double>, clockwise: Bool, opacity: Double, in g: GraphicsContext) {
        let mid = (lit.lowerBound + lit.upperBound) / 2 * .pi / 180
        let c = CGPoint(x: ring.center.x + ring.radius * cos(mid), y: ring.center.y + ring.radius * sin(mid))
        // The tangent, clockwise in y-down coordinates.
        let dir: CGFloat = clockwise ? 1 : -1
        let (ux, uy) = (-sin(mid) * dir, cos(mid) * dir)
        let size = max(6, ring.thickness * 0.6 + 3)
        var head = Path()
        head.move(to: CGPoint(x: c.x - ux * size - uy * size, y: c.y - uy * size + ux * size))
        head.addLine(to: CGPoint(x: c.x + ux * size * 0.6, y: c.y + uy * size * 0.6))
        head.addLine(to: CGPoint(x: c.x - ux * size + uy * size, y: c.y - uy * size - ux * size))
        g.stroke(head, with: .color(Theme.ink.opacity(opacity)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }
}

/// Each arc's motion between frames. Not observed: the Canvas steps it and
/// nothing else reads it, so it redraws nothing.
@MainActor
private final class RingClock {
    private var motions: [EnergyNode: Flow.RingMotion] = [:]

    func frame(_ target: Flow.BeamTarget, at t: Double, reduceMotion: Bool) -> Flow.RingFrame {
        var m = motions[target.node] ?? Flow.RingMotion(target, at: t)
        let f = m.step(target, at: t, reduceMotion: reduceMotion)
        motions[target.node] = m
        return f
    }
}

/// What a long press on the car can do: each of Charge now, Pause and Back
/// to the plan that is not what the charger does already. Nil when there
/// is no car plugged in or this phone may not command it.
struct CarActions {
    var chargeNow: (() -> Void)?
    var pause: (() -> Void)?
    var backToPlan: (() -> Void)?
}

/// The car's long-press menu, only where there is something to offer.
private struct CarMenu: ViewModifier {
    let actions: CarActions?

    func body(content: Content) -> some View {
        if let actions {
            content.contextMenu {
                if let run = actions.chargeNow { Button(L("Charge now"), systemImage: "bolt.fill", action: run) }
                if let run = actions.pause { Button(L("Pause"), systemImage: "pause.fill", action: run) }
                if let run = actions.backToPlan { Button(L("Back to the plan"), systemImage: "calendar.badge.clock", action: run) }
            }
        } else {
            content
        }
    }
}

/// A node's door: the press goes down to the label, which closes the
/// lock-on on its own text.
private struct LockOnPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.lockedOn, configuration.isPressed)
            .contentShape(Rectangle().inset(by: -8))
    }
}

extension EnvironmentValues {
    /// A finger is on this node.
    @Entry var lockedOn = false
}

/// The lock-on under a finger: four 7 pt corner brackets close on what is
/// pressed, from 1.15× to its size, with the app's spring. Nothing else
/// moves.
private struct LockOnBrackets: View {
    let on: Bool

    var body: some View {
        Brackets()
            .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .padding(-6)
            .scaleEffect(on ? 1 : 1.15)
            .opacity(on ? 1 : 0)
            .animation(Theme.spring, value: on)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Four corners of a rectangle, 7 pt arms.
private struct Brackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 7
        var p = Path()
        for (corner, sx, sy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0), (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
        }
        return p
    }
}

/// One node of the flow, as text on the ground in three fixed rows: the
/// symbol and name in its energy's colour, the figure, and what it does
/// with the battery's or the car's level beside it ("Charging · 68 %", "≈
/// 20 %" for a level FTW assumes). Every row is kept, filled or not, so
/// nothing moves when a word or a level arrives. Light means live: a node
/// the box has not confirmed live is ink, its name and symbol too, and
/// the status line says how old.
struct NodeLabel: View, Equatable {
    let reading: NodeReading
    let spot: FlowPlan.Spot
    /// Of the label's size, where the room is short (`RingGeometry`).
    var scale: CGFloat = 1
    /// The name stops at a large size; the figure grows on.
    @ScaledMetric(relativeTo: .subheadline) private var scaledName: CGFloat = 15
    private var name: CGFloat { min(scaledName, 18) * scale }
    @ScaledMetric(relativeTo: .title) private var scaledFigure: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var scaledUnit: CGFloat = 15
    @ScaledMetric(relativeTo: .footnote) private var scaledWord: CGFloat = 14
    private var figure: CGFloat { scaledFigure * scale }
    private var unit: CGFloat { scaledUnit * scale }
    private var word: CGFloat { scaledWord * scale }
    @Environment(\.lockedOn) private var lockedOn

    nonisolated static func == (a: Self, b: Self) -> Bool { a.reading == b.reading && a.spot == b.spot && a.scale == b.scale }

    var body: some View {
        let live = reading.freshness.live
        let hue = NodeLook.hue(reading)
        VStack(alignment: spot.horizontal, spacing: 1) {
            // The symbol on the outer side: before the name on the left,
            // after it on the right.
            HStack(spacing: 5) {
                if !spot.trailing { symbol }
                Text(reading.node.title)
                    .font(.system(size: name, weight: .semibold))
                    .minimumScaleFactor(0.75)
                if spot.trailing { symbol }
            }
            .foregroundStyle(live ? hue : Theme.ink2)
            .lineLimit(1)
            NodeValue(watts: reading.watts, size: figure, unit: unit)
                .foregroundStyle(reading.watts == nil || !live ? Theme.ink2 : Theme.ink)
            Text(NodeLook.doing(reading))
                .font(.system(size: word))
                .foregroundStyle(live ? Theme.ink2 : Theme.ink3)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .overlay { LockOnBrackets(on: lockedOn) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.node.title)
        .accessibilityValue(NodeLook.spoken(reading))
        .accessibilityHint(L("Opens live readings, history and the plan."))
    }
}

extension NodeLabel {
    private var symbol: some View {
        Image(systemName: NodeLook.symbol(reading.node, levelPct: reading.levelPct, flowing: reading.flowing))
            .font(.system(size: name, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The home in the middle of the ring, everything it uses right now: its
/// symbol, the figure, its unit and its name, inside a thin circle of ink.
/// The type grows with the text up to what the circle holds, and a small
/// circle leaves the symbol out, so the figure is never cut.
struct HubLabel: View, Equatable {
    let reading: NodeReading
    let diameter: CGFloat
    @ScaledMetric(relativeTo: .largeTitle) private var scaledFigure: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var scaledWord: CGFloat = 13
    private var figure: CGFloat { min(scaledFigure, diameter * 0.38) }
    private var word: CGFloat { min(scaledWord, diameter * 0.12) }
    /// Room for the symbol over the figure.
    private var symbol: Bool { diameter >= 110 }
    @Environment(\.lockedOn) private var lockedOn
    /// The figure on screen, held on a rounding edge.
    @State private var held: Double?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.reading == b.reading && a.diameter == b.diameter }

    var body: some View {
        let live = reading.freshness.live
        let shown = reading.watts.map { Flow.quantised($0, holding: held) }
        let parts = shown.map(PowerFormat.parts)
        VStack(spacing: 0) {
            if symbol {
                Image(systemName: "house.fill")
                    .font(.system(size: word + 3, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.bottom, 2)
            }
            Text(parts.map { AppWords.decimal($0.text) } ?? "—")
                .font(Theme.figure(figure))
                .tracking(-1)
                .foregroundStyle(reading.watts == nil || !live ? Theme.ink2 : Theme.ink)
                .contentTransition(.numericText(value: shown ?? 0))
                .animation(Theme.spring, value: shown)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .onChange(of: shown, initial: true) { _, now in held = now }
            Text(parts?.unit ?? "W")
                .font(.system(size: word, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Text(EnergyNode.home.title)
                .font(.system(size: word))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(width: diameter, height: diameter)
        .background(Circle().strokeBorder(Theme.ink.opacity(0.16), lineWidth: 1))
        .overlay { LockOnBrackets(on: lockedOn) }
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EnergyNode.home.title)
        .accessibilityValue(NodeLook.spoken(reading))
        .accessibilityHint(L("Opens live readings, history and the plan."))
    }
}

/// "630 W", "7,2 kW": figure and unit, quantised (`Flow.quantised`), so
/// the figure rolls when its digits change and not every second, and held
/// on a rounding edge, so 1.45 kW does not wobble between 1.4 and 1.5.
struct NodeValue: View {
    let watts: Double?
    let size: CGFloat
    var unit: CGFloat?
    /// The figure on screen.
    @State private var held: Double?

    var body: some View {
        if let watts {
            let shown = Flow.quantised(watts, holding: held)
            let parts = PowerFormat.parts(shown)
            Text("\(Text(AppWords.decimal(parts.text)).font(Theme.figure(size)))\(Text(" \(parts.unit)").font(unit.map { .system(size: $0, weight: .medium) } ?? .caption).foregroundStyle(Theme.ink2))")
                .contentTransition(.numericText(value: shown))
                .animation(Theme.spring, value: shown)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .onChange(of: shown, initial: true) { _, now in held = now }
        } else {
            Text("—").font(Theme.figure(size))
        }
    }
}

/// How each node looks and is named, in one place, so Now and a node's own
/// view never call one thing two names.
enum NodeLook {
    static func symbol(_ node: EnergyNode, levelPct: Double? = nil, flowing: Bool = false) -> String {
        switch node {
        case .solar: return "sun.max.fill"
        case .battery:
            let pct = levelPct ?? 50
            let step = pct >= 88 ? 100 : pct >= 63 ? 75 : pct >= 38 ? 50 : pct >= 13 ? 25 : 0
            return "battery.\(step)percent"
        case .home: return "house.fill"
        case .grid: return "bolt.fill"
        case .car: return flowing ? "bolt.car.fill" : "car.side.fill"
        }
    }

    /// The node's own colour for its name: its kind, and for the battery
    /// which way it runs. At rest it keeps its kind's colour; only its beam
    /// goes still.
    static func hue(_ r: NodeReading) -> Color {
        switch r.node {
        case .solar: return Theme.solar
        case .battery: return r.tone == .discharging ? Theme.gives : Theme.stores
        case .home: return Theme.ink
        case .grid: return Theme.grid
        case .car: return Theme.car
        }
    }

    /// What a node does, as Now writes it under its figure: the word with a
    /// capital, and the battery's or the car's level after it, "Charging ·
    /// 68 %", or "≈ 20 %" for a car level FTW assumes, as the car row and
    /// the car view write it. A space when there is nothing yet, so the row
    /// keeps its height.
    static func doing(_ r: NodeReading) -> String {
        let word = r.word.prefix(1).uppercased() + r.word.dropFirst()
        guard let level = r.levelPct else { return word.isEmpty ? " " : word }
        let pct = (r.levelAssumed ? "≈\u{00A0}" : "") + AppWords.percent(level)
        return word.isEmpty ? pct : "\(word) · \(pct)"
    }

    /// "2 min ago", or that the box cannot say.
    static func age(_ f: NodeFreshness) -> String {
        if f.srcState == .never { return L("no reading") }
        guard let ms = f.ageMs else { return L("not live") }
        return PowerFormat.age(ms)
    }

    /// What VoiceOver reads for a node: the figure, the direction, how
    /// full, and whether it is live.
    static func spoken(_ r: NodeReading) -> String {
        var parts = [String]()
        if let w = r.watts { parts.append(AppWords.power(w)) }
        parts.append(r.word)
        if let level = r.levelPct {
            parts.append(r.levelAssumed ? NodeWords.format("about %@", AppWords.percent(level)) : AppWords.percent(level))
        }
        parts.append(r.freshness.live ? L("live") : age(r.freshness))
        return parts.joined(separator: ", ")
    }
}
