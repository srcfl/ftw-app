import FTWKit
import SwiftUI

/// The home and what flows through it, laid out as the box's own dashboard
/// lays it out: the sun top left, the battery top right, the grid bottom
/// left, the car bottom right, and the home's own use in the ring in the
/// middle. A node whose partner across the middle is missing moves onto the
/// middle axis (`FlowPlan`). Each node is text on the ground, with no box,
/// and a door to its own view that grows out of it.
///
/// Between them run straight beams of light. A beam's width says the power
/// and a soft wave of light runs along it from source to sink, faster with
/// more power; it glows in the dark. Only a reading the box confirmed live
/// glows or moves: a cached or quiet beam is a faint still line, and a node
/// at rest is a still dotted hairline. No dot travels anywhere.
struct FlowDiagram: View {
    let readings: [NodeReading]
    let zoom: Namespace.ID
    /// Charge now, Pause and Back to the plan, held on the car.
    var car: CarActions?
    @State private var frames: [EnergyNode: CGRect] = [:]
    @ScaledMetric(relativeTo: .largeTitle) private var hubSize: CGFloat = 92

    var body: some View {
        GeometryReader { geo in
            let nodes = readings.map(\.node)
            // The ring grows a little with the text, no more: past that it
            // takes the nodes' room.
            let ring = min(hubSize, 100)
            let hub = CGRect(x: geo.size.width / 2 - ring / 2, y: geo.size.height / 2 - ring / 2, width: ring, height: ring)
            let width = Self.nodeWidth(geo.size.width, hub: ring)
            ZStack {
                FlowBeams(beams: beams(nodes: nodes, hub: hub))
                    .accessibilityHidden(true)
                ForEach(readings.filter { $0.node != .home }) { r in
                    let spot = FlowPlan.spot(r.node, among: nodes)
                    // The node's place is a fixed frame, so neither a beam
                    // nor the door moves when a word or a figure changes
                    // width; the whole frame takes the finger.
                    door(r) { NodeLabel(reading: r, spot: spot).equatable().frame(width: width, alignment: spot.textAlignment) }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[r.node] = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spot.alignment)
                }
                if let home = readings.first(where: { $0.node == .home }) {
                    door(home) { HubLabel(reading: home, diameter: ring).equatable() }
                        .position(x: hub.midX, y: hub.midY)
                }
            }
        }
        .coordinateSpace(.named(Self.space))
    }

    nonisolated static let space = "flow"

    /// As wide as the room beside the hub allows, within reason.
    static func nodeWidth(_ width: CGFloat, hub: CGFloat) -> CGFloat {
        min(132, max(88, (width - hub - 40) / 2))
    }

    private func door<Label: View>(_ r: NodeReading, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: HomeRoute.node(r.node)) { label() }
            .buttonStyle(LockOnPress())
            .modifier(CarMenu(actions: r.node == .car ? car : nil))
            .matchedTransitionSource(id: HomeRoute.node(r.node), in: zoom)
            .accessibilityIdentifier("now.node.\(r.node.rawValue)")
    }

    private func beams(nodes: [EnergyNode], hub: CGRect) -> [FlowBeams.Beam] {
        readings.compactMap { r in
            guard r.node != .home, let frame = frames[r.node],
                  let ends = FlowPlan.beam(node: frame, at: FlowPlan.spot(r.node, among: nodes), hub: hub) else { return nil }
            let target = Flow.BeamTarget(r)
            let (from, to) = target.towardHome ? (ends.node, ends.hub) : (ends.hub, ends.node)
            return FlowBeams.Beam(target: target, from: from, to: to, color: Theme.color(r.tone))
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

/// The beams, in one Canvas inside one `TimelineView`. The light runs at the
/// display's rate while a beam is live and Now is on screen in an active
/// app, at 20 frames a second in Low Power Mode, and for a moment after a
/// change so a beam can swell, ignite or cool; otherwise the timeline rests
/// and nothing draws. Under Reduce Motion the light holds still, ignite and
/// decay are instant, and a still chevron mid-beam says which way it flows.
private struct FlowBeams: View {
    struct Beam: Equatable {
        let target: Flow.BeamTarget
        /// Source to sink: the light runs this way.
        let from: CGPoint
        let to: CGPoint
        let color: Color
    }

    let beams: [Beam]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var clock = BeamClock()
    /// Changes seen, and the last one the beams have settled after.
    @State private var changes = 0
    @State private var settled = 0

    /// Long enough for a width to swell (τ 0.4 s) and a glow to cool.
    static let settle: Duration = .milliseconds(2_400)

    var body: some View {
        let lowPower = PowerState.shared.lowPower
        let waving = beams.contains { $0.target.live && $0.target.flowing }
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
        .onChange(of: beams.map(\.target)) { changes += 1 }
        .task(id: changes) {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            settled = changes
        }
    }

    private func draw(_ g: inout GraphicsContext, at t: Double, still: Bool) {
        let px = 1 / max(g.environment.displayScale, 1)
        for beam in beams {
            let f = clock.frame(beam.target, at: t, reduceMotion: still)
            let length = hypot(beam.to.x - beam.from.x, beam.to.y - beam.from.y)
            guard length > 1 else { continue }
            var path = Path()
            path.move(to: beam.from)
            path.addLine(to: beam.to)
            // At rest: the still dotted hairline, cross-faded with the beam
            // as a node starts or stops.
            if f.idle > 0.01 { TraceInk.dotted(path, px: px, opacity: f.idle, in: g) }
            let k = 1 - f.idle
            guard k > 0.01 else { continue }
            let width = CGFloat(f.width)
            if TraceInk.glows(live: f.light > 0.004, in: g) {
                TraceInk.glow(path, color: beam.color, width: width, strength: f.light * k, in: g)
            }
            let color = beam.color.resolve(in: g.environment)
            g.stroke(path, with: .linearGradient(Gradient(stops: Self.stops(length: Double(length), f, color, k)), startPoint: beam.from, endPoint: beam.to), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if still, beam.target.flowing { chevron(beam, width: width, opacity: f.alpha * k, in: g) }
        }
    }

    /// The core's brightness along the beam as gradient stops. Inside, the
    /// stops sit on the wave's own grid, ten to a wavelength, so a crest
    /// keeps its exact shape as it runs instead of shimmering between
    /// fixed stops.
    static func stops(length: Double, _ f: Flow.BeamFrame, _ color: Color.Resolved, _ k: Double) -> [Gradient.Stop] {
        func stop(_ s: Double) -> Gradient.Stop {
            let b = f.alpha * (1 - f.depth * (1 - Flow.wave(s, phase: f.phase))) * k
            var c = color
            c.opacity *= Float(b)
            return Gradient.Stop(color: Color(c), location: s / length)
        }
        guard f.depth > 0.001 else { return [stop(0), stop(length)] }
        let step = Flow.wavelength / 10
        let q = f.phase * 10 - (f.phase * 10).rounded(.down)
        var out = [stop(0)]
        var s = step * q
        while s < length {
            if s > 0 { out.append(stop(s)) }
            s += step
        }
        out.append(stop(length))
        return out
    }

    /// A still chevron halfway along a beam, pointing the way power flows:
    /// 6 pt, and wider than a wide beam. A mark of the interface, so in ink.
    private func chevron(_ beam: Beam, width: CGFloat, opacity: Double, in g: GraphicsContext) {
        let (a, b) = (beam.from, beam.to)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let (ux, uy) = (dx / length, dy / length)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = max(6, width * 0.6 + 3)
        var head = Path()
        head.move(to: CGPoint(x: mid.x - ux * size - uy * size, y: mid.y - uy * size + ux * size))
        head.addLine(to: CGPoint(x: mid.x + ux * size * 0.6, y: mid.y + uy * size * 0.6))
        head.addLine(to: CGPoint(x: mid.x - ux * size + uy * size, y: mid.y - uy * size - ux * size))
        g.stroke(head, with: .color(Theme.ink.opacity(opacity)), style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }
}

/// Each beam's motion between frames. Not observed: the Canvas steps it and
/// nothing else reads it, so it redraws nothing.
@MainActor
private final class BeamClock {
    private var motions: [EnergyNode: Flow.BeamMotion] = [:]

    func frame(_ target: Flow.BeamTarget, at t: Double, reduceMotion: Bool) -> Flow.BeamFrame {
        var m = motions[target.node] ?? Flow.BeamMotion(target, at: t)
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

/// One node of the flow, as text on the ground in four fixed rows: the
/// symbol and name in its energy's colour, the figure, one word for what it
/// does, and a row for the battery's or the car's level that every node
/// keeps, so nothing moves when a level arrives. A figure the box has not
/// confirmed live is drawn in a softer ink; the status line says how old.
struct NodeLabel: View, Equatable {
    let reading: NodeReading
    let spot: FlowPlan.Spot
    /// The name stops at the default size; the figure grows on.
    @ScaledMetric(relativeTo: .caption2) private var scaledName: CGFloat = 11
    private var name: CGFloat { min(scaledName, 11) }
    @ScaledMetric(relativeTo: .title2) private var figure: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var unit: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var word: CGFloat = 13
    @Environment(\.lockedOn) private var lockedOn

    nonisolated static func == (a: Self, b: Self) -> Bool { a.reading == b.reading && a.spot == b.spot }

    var body: some View {
        let live = reading.freshness.live
        let hue = NodeLook.hue(reading)
        VStack(alignment: spot.horizontal, spacing: 1) {
            // The symbol on the outer side: before the name on the left,
            // after it on the right.
            HStack(spacing: 4) {
                if !spot.trailing { symbol }
                Text(reading.node.caps)
                    .font(.system(size: name, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .minimumScaleFactor(0.75)
                if spot.trailing { symbol }
            }
            .foregroundStyle(hue)
            .lineLimit(1)
            NodeValue(watts: reading.watts, size: figure, unit: unit)
                .foregroundStyle(reading.watts == nil || !live ? Theme.ink2 : Theme.ink)
                .padding(.top, 1)
            // Every row is kept, filled or not, so a node never changes
            // height when its word or level arrives.
            Text(reading.word.isEmpty ? " " : reading.word)
                .font(.system(size: word))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            CellMeter(pct: reading.levelPct ?? 0, tint: reading.node == .car ? Theme.car : Theme.stores, live: live && !reading.levelAssumed)
                .frame(width: 50, height: 4)
                .padding(.top, 4)
                .opacity(reading.levelPct == nil ? 0 : 1)
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

/// The home in the middle, everything it uses right now, in the screen's
/// only round shape: a thin ring of ink.
struct HubLabel: View, Equatable {
    let reading: NodeReading
    let diameter: CGFloat
    @ScaledMetric(relativeTo: .largeTitle) private var figure: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var word: CGFloat = 12
    @Environment(\.lockedOn) private var lockedOn
    /// The figure on screen, held on a rounding edge.
    @State private var held: Double?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.reading == b.reading && a.diameter == b.diameter }

    var body: some View {
        let live = reading.freshness.live
        let shown = reading.watts.map { Flow.quantised($0, holding: held) }
        let parts = shown.map(PowerFormat.parts)
        VStack(spacing: 0) {
            Text(parts.map { AppWords.decimal($0.text) } ?? "—")
                .font(Theme.figure(figure))
                .tracking(-1)
                .foregroundStyle(reading.watts == nil || !live ? Theme.ink2 : Theme.ink)
                .contentTransition(.numericText(value: shown ?? 0))
                .animation(Theme.spring, value: shown)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .onChange(of: shown, initial: true) { _, now in held = now }
            Text(NodeWords.format("%@ · home", parts?.unit ?? "W"))
                .font(.system(size: word))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .frame(width: diameter, height: diameter)
        .background(Circle().strokeBorder(Theme.ink.opacity(0.28), lineWidth: 1))
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
        if let level = r.levelPct { parts.append(AppWords.percent(level)) }
        parts.append(r.freshness.live ? L("live") : age(r.freshness))
        return parts.joined(separator: ", ")
    }
}
