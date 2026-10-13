import FTWKit
import SwiftUI

/// The home and what flows through it, laid out as the box's own dashboard
/// lays it out: the sun top left, the battery top right, the grid bottom
/// left, the car bottom right, and the home's own use in the middle. Each
/// node is a door to its own view, and grows into it.
///
/// Dots move along a line only while that node's reading is live. A cached,
/// quiet or lagging node holds still and says how old it is, because motion
/// claims power is flowing right now.
struct FlowDiagram: View {
    let readings: [NodeReading]
    let zoom: Namespace.ID
    /// Charge now, Pause and Back to the plan, held on the car's bubble.
    var car: CarActions?
    @State private var frames: [EnergyNode: CGRect] = [:]

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack {
                FlowLines(lines: lines(m), moving: readings.contains { $0.node != .home && $0.flowing && $0.freshness.live })
                    .accessibilityHidden(true)
                ForEach(readings.filter { $0.node != .home }) { r in
                    door(r) { NodeBubble(reading: r, width: m.bubbleWidth, scale: m.scale).equatable() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: m.alignment(r.node))
                }
                if let home = readings.first(where: { $0.node == .home }) {
                    door(home) { HubBubble(reading: home, diameter: m.hubDiameter, scale: m.scale).equatable() }
                }
            }
            .frame(width: m.box.width, height: m.box.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .coordinateSpace(.named(Self.space))
        // A drawing with fixed places: past this size its labels would
        // collide, and every figure in it is also said in the node's view.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    nonisolated static let space = "flow"

    private func door<Label: View>(_ r: NodeReading, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: HomeRoute.node(r.node)) { label() }
            .buttonStyle(PressStyle())
            .modifier(CarMenu(actions: r.node == .car ? car : nil))
            .matchedTransitionSource(id: HomeRoute.node(r.node), in: zoom)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[r.node] = $0 }
            .accessibilityIdentifier("now.node.\(r.node.rawValue)")
    }

    private func lines(_ m: Metrics) -> [FlowLines.Line] {
        guard let hub = frames[.home] else { return [] }
        let to = CGPoint(x: hub.midX, y: hub.midY)
        return readings.compactMap { r in
            guard r.node != .home, let f = frames[r.node] else { return nil }
            return FlowLines.Line(
                from: CGPoint(x: f.midX, y: f.midY),
                to: to,
                color: Theme.color(r.tone),
                active: r.flowing && r.freshness.live,
                towardHub: r.towardHome,
                kw: (r.watts ?? 0) / 1000
            )
        }
    }

    /// Sizes from the room there is. The drawing never grows taller than
    /// a little over its width: past that the corners only drift apart. On
    /// a tall phone the figures grow with it, so the room reads as size
    /// rather than as empty space.
    struct Metrics {
        let box: CGSize
        let scale: CGFloat
        let bubbleWidth: CGFloat
        let hubDiameter: CGFloat

        init(size: CGSize) {
            box = CGSize(width: size.width, height: min(size.height, size.width * 1.2))
            scale = min(1.25, max(1, box.height / 380))
            bubbleWidth = min(136, max(96, size.width * 0.3)) * min(scale, 1.1)
            hubDiameter = min(132 * scale, max(104, min(size.width * 0.34, box.height * 0.42)))
        }

        func alignment(_ node: EnergyNode) -> Alignment {
            switch node {
            case .solar: return .topLeading
            case .battery: return .topTrailing
            case .grid: return .bottomLeading
            case .car: return .bottomTrailing
            case .home: return .center
            }
        }
    }
}

/// The lines between the nodes and the home, and the dots that run along
/// the live ones, at the display's own rate while something moves and Now
/// is on screen in an active app. Low Power Mode drops the rate to 20 a
/// second; Reduce Motion stills the dots and marks each live line with an
/// arrow for its direction instead.
private struct FlowLines: View {
    struct Line {
        let from: CGPoint
        let to: CGPoint
        let color: Color
        let active: Bool
        let towardHub: Bool
        let kw: Double
    }

    let lines: [Line]
    let moving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

    private var lowPower: Bool { PowerState.shared.lowPower }

    var body: some View {
        let still = reduceMotion || !moving
        let paused = still || !onScreen || scenePhase != .active
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 20 : nil, paused: paused)) { context in
            Canvas { canvas, _ in
                draw(canvas, at: context.date.timeIntervalSinceReferenceDate, still: still)
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private func draw(_ canvas: GraphicsContext, at time: TimeInterval, still: Bool) {
        for line in lines {
            var path = Path()
            path.move(to: line.from)
            path.addLine(to: line.to)
            canvas.stroke(path, with: .color(line.active ? line.color.opacity(0.45) : Theme.line), style: StrokeStyle(lineWidth: line.active ? 2 : 1.5, lineCap: .round, dash: line.active ? [] : [3, 5]))
            guard line.active else { continue }
            if still {
                arrow(canvas, line)
                continue
            }
            // Speed grows with power but never races: a kettle and a car
            // charger are both readable at a glance, at most about 0.8
            // lengths a second.
            let speed = 0.2 + min(0.6, log10(1 + line.kw) * 0.5)
            let dots = 4
            for i in 0..<dots {
                var t = (time * speed + Double(i) / Double(dots)).truncatingRemainder(dividingBy: 1)
                if !line.towardHub { t = 1 - t }
                let p = CGPoint(x: line.from.x + (line.to.x - line.from.x) * t, y: line.from.y + (line.to.y - line.from.y) * t)
                canvas.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(line.color))
            }
        }
    }

    /// A still chevron halfway along a live line, pointing the way power
    /// flows.
    private func arrow(_ canvas: GraphicsContext, _ line: Line) {
        let (a, b) = line.towardHub ? (line.from, line.to) : (line.to, line.from)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        let (ux, uy) = (dx / length, dy / length)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size: CGFloat = 6
        var head = Path()
        head.move(to: CGPoint(x: mid.x - ux * size - uy * size, y: mid.y - uy * size + ux * size))
        head.addLine(to: CGPoint(x: mid.x + ux * size * 0.6, y: mid.y + uy * size * 0.6))
        head.addLine(to: CGPoint(x: mid.x - ux * size + uy * size, y: mid.y - uy * size - ux * size))
        canvas.stroke(head, with: .color(line.color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
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

/// A slight give under the finger, as a system button has.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

/// One corner of the flow: what it is, how much, which way, and how full
/// for the battery and the car. A reading that is not live says how old it
/// is in place of looking live.
struct NodeBubble: View, Equatable {
    let reading: NodeReading
    let width: CGFloat
    var scale: CGFloat = 1

    var body: some View {
        let live = reading.freshness.live
        let color = live ? Theme.color(reading.tone) : Theme.fgMuted
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: NodeLook.symbol(reading.node, levelPct: reading.levelPct, flowing: reading.flowing))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .contentTransition(.symbolEffect(.replace))
                Text(reading.node.caps)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.fgDim)
            }
            NodeValue(watts: reading.watts, size: 18 * scale)
                .foregroundStyle(reading.watts == nil ? Theme.fgMuted : color)
            Text(reading.word)
                .font(.caption2)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
            if let level = reading.levelPct {
                LevelBar(pct: level, assumed: reading.levelAssumed, tint: reading.node == .car ? Theme.mobility : Theme.storage)
            }
            if !live, reading.watts != nil {
                FreshnessTag(freshness: reading.freshness)
            }
        }
        .padding(.vertical, 8 * scale)
        .padding(.horizontal, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(color.opacity(live ? 0.55 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: live ? [] : [4, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .animation(Theme.spring, value: reading.word)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.node.title)
        .accessibilityValue(NodeLook.spoken(reading))
        .accessibilityHint(L("Opens live readings, history and the plan."))
    }
}

/// The home in the middle: everything it is using right now.
struct HubBubble: View, Equatable {
    let reading: NodeReading
    let diameter: CGFloat
    var scale: CGFloat = 1

    var body: some View {
        let live = reading.freshness.live
        VStack(spacing: 1) {
            Image(systemName: "house.fill")
                .font(.title3)
                .foregroundStyle(live ? Theme.accent : Theme.fgMuted)
            NodeValue(watts: reading.watts, size: 22 * scale)
                .foregroundStyle(Theme.fg)
            Text(EnergyNode.home.caps)
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !live, reading.watts != nil {
                FreshnessTag(freshness: reading.freshness)
            }
        }
        .padding(8)
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(Theme.surfaceElevated))
        .overlay(Circle().strokeBorder((live ? Theme.accentFill : Theme.fgMuted).opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: live ? [] : [4, 3])))
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EnergyNode.home.title)
        .accessibilityValue(NodeLook.spoken(reading))
        .accessibilityHint(L("Opens live readings, history and the plan."))
    }
}

/// "632 W", "7,2 kW": figure and unit, the figure rolling as it changes.
struct NodeValue: View {
    let watts: Double?
    let size: CGFloat

    var body: some View {
        if let watts {
            let parts = PowerFormat.parts(watts)
            Text("\(Text(AppWords.decimal(parts.text)).font(Theme.figure(size)))\(Text(" \(parts.unit)").font(.caption))")
                .contentTransition(.numericText(value: watts))
                .animation(Theme.spring, value: watts)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text("—").font(Theme.figure(size))
        }
    }
}

/// How full, as a bar and a figure. An assumed level is drawn hollow.
struct LevelBar: View {
    let pct: Double
    let assumed: Bool
    let tint: Color
    var showsFigure = true

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule()
                        .fill(assumed ? tint.opacity(0.35) : tint)
                        .frame(width: geo.size.width * min(1, max(0, pct / 100)))
                }
            }
            .frame(width: 36, height: 5)
            if showsFigure {
                Text(AppWords.percent(pct))
                    .font(Theme.percent(.caption2, weight: .medium))
                    .foregroundStyle(assumed ? Theme.fgMuted : Theme.fg)
                    .contentTransition(.numericText(value: pct))
            }
        }
    }
}

/// A reading that is not live, said as its age.
struct FreshnessTag: View {
    let freshness: NodeFreshness

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
            Text(NodeLook.age(freshness))
        }
        .font(.caption2)
        .foregroundStyle(Theme.freshStale)
        .lineLimit(1)
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
