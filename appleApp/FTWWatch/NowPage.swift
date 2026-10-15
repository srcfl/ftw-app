import FTWShared
import SwiftUI
import WatchKit

/// Now, alive, on one screen: the status line, one node's figure large,
/// its trace of the last three minutes, and the other nodes small. A tap
/// on a small one makes it the traced one; a drag across the trace reads
/// it. The trace opens whole, in ink, and glows only while the phone
/// passes on live frames; anything else is ink with the minute it was
/// read. How the home is run sits behind the toolbar's button, by name.
struct NowPage: View {
    let model: WatchModel
    /// Always On redraws once a minute: a figure lit then would show an old
    /// reading as live, so nothing glows while the wrist is down.
    @Environment(\.isLuminanceReduced) private var dim
    /// The reading under a finger on the trace.
    @State private var held: LiveSample?

    var body: some View {
        let lit = model.lit && !dim
        let known = model.now != nil
        let figures = WatchGlance.figures(model.now?.value ?? WatchNow.shape, lit: lit)
        let traced = figures.first { $0.node == model.trace.node } ?? figures.first
        let hero = held.map { WatchGlance.figure(model.trace.node, at: $0) } ?? traced
        let rest = figures.filter { $0.node != traced?.node }
        let status = WatchGlance.status(model.now, lit: lit, demo: model.context?.isDemo == true, zone: model.zone, receipt: model.lineReceipt)
        OnePage {
            VStack(alignment: .leading, spacing: Self.compact ? 2 : 4) {
                StatusLine(status: status)
                    // Clear of the page dots at the right edge.
                    .padding(.trailing, StatusLine.clearOfDots)
                Group {
                    if let hero {
                        HeroFigure(figure: hero, way: held == nil ? model.now?.value.reading(hero.node)?.way ?? .resting : WatchGlance.way(hero.node, signedW: held?.v ?? 0), traceLit: lit)
                    }
                    // Whatever height is left, so Now fits 40 mm as well as 46.
                    TraceView(trace: model.trace, live: lit, zone: model.zone, held: $held)
                        .frame(minHeight: Self.compact ? 16 : 24, maxHeight: .infinity)
                    SmallFigures(figures: rest, now: model.now?.value) { model.follow($0) }
                }
                .redacted(reason: known ? [] : .placeholder)
                .disabled(!known)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .pageSpace()
        // A home without the traced node (no car, no sun) traces its first.
        .onChange(of: figures.map(\.node), initial: true) { _, nodes in
            if known, let first = nodes.first, !nodes.contains(model.trace.node) { model.trace.follow(first) }
        }
        .toolbar { modeButton }
    }

    /// The lowest screens (40 mm, 197 pt): a smaller large figure and
    /// tighter gaps, so Now fits without scrolling and the rows keep their
    /// 30 pt.
    static let compact = WKInterfaceDevice.current().screenBounds.height < 205

    @ToolbarContentBuilder private var modeButton: some ToolbarContent {
        if let modes = model.context?.modes, let name = modeName(modes) {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ModeList(model: model, modes: modes)
                } label: {
                    Text(name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .animation(Theme.spring, value: name)
                .accessibilityLabel(WatchWord.mode.text)
                .accessibilityValue(name)
                .accessibilityIdentifier("watch.mode")
            }
        }
    }

    /// The mode by name, as the phone's button says it: "Plan" while the
    /// planner runs the home, else the manual mode's name. A choice on its
    /// way shows at once; the status line carries the box's receipt.
    private func modeName(_ modes: WatchModes) -> String? {
        var key = modes.shown
        if let r = model.receipt(for: WatchModel.modeTarget), !r.settled, case .mode(let asked) = r.op { key = asked }
        guard let key, let mode = modes.modes.first(where: { $0.key == key }) else { return modes.label }
        return mode.isPlan ? WatchWord.planTitle.text : mode.name
    }
}

/// Each node's glyph, so a small figure needs no word.
enum NodeGlyph {
    static func name(_ node: WatchNow.Node) -> String {
        switch node {
        case .solar: return "sun.max.fill"
        case .battery: return "battery.75percent"
        case .home: return "house.fill"
        case .grid: return "powerplug.fill"
        case .car: return "car.fill"
        }
    }
}

/// A node's glyph with the way it runs marked beside it in ink: ▲ while
/// the battery stores or the home buys, ▼ while it gives or sells, as the
/// trace draws them. It reads without colour, so a cached figure says it
/// too. The battery's and the grid's mark keeps its room at rest, so their
/// figures do not move when a direction comes or goes.
private struct NodeMark: View {
    let node: WatchNow.Node
    let direction: WatchGlance.Direction?
    let size: CGFloat
    let color: Color
    /// The short line under the glyph that marks the traced node, in this
    /// colour.
    var traced: Color?

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            Image(systemName: NodeGlyph.name(node))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .overlay(alignment: .bottom) {
                    if let traced {
                        Capsule()
                            .fill(traced)
                            .frame(width: size, height: 2.5)
                            .offset(y: size * 0.45)
                    }
                }
            if node == .battery || node == .grid {
                Image(systemName: direction == .down ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .opacity(direction == nil ? 0 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .animation(Theme.spring, value: direction)
    }
}

/// The traced node: its glyph, the figure large, and its word. A short line
/// in its hue under the glyph marks it as the one the trace draws; it is
/// lit only while the trace is.
private struct HeroFigure: View {
    let figure: WatchGlance.Figure
    let way: WatchNow.Way
    /// The trace glows, so its mark under the glyph takes the node's hue.
    let traceLit: Bool

    var body: some View {
        let hue = figure.lit ? Hue.of(figure.node, way: way) : Theme.ink
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            NodeMark(node: figure.node, direction: figure.direction, size: 14, color: figure.lit ? hue : Theme.ink2, traced: traceLit ? Hue.of(figure.node, way: way) : Theme.ink2)
                .padding(.trailing, 2)
            Text(figure.value)
                .font(Theme.figure(NowPage.compact ? 27 : 32))
                .foregroundStyle(hue)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(figure.unit)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 2)
            Text(figure.level ?? figure.word)
                .font(.caption2)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .animation(Theme.spring, value: figure.value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(figure.title), \(figure.value) \(figure.unit), \(figure.word)")
        .accessibilityIdentifier("watch.now.hero")
    }
}

/// The other nodes, small, two to a row: glyph with its direction, figure
/// and unit. Each row is at least 30 pt tall, a whole half of the width to
/// hit; a tap traces it.
private struct SmallFigures: View {
    let figures: [WatchGlance.Figure]
    let now: WatchNow?
    let choose: (WatchNow.Node) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: figures.count, by: 2)), id: \.self) { i in
                GridRow {
                    small(figures[i])
                    if i + 1 < figures.count { small(figures[i + 1]) }
                }
            }
        }
    }

    private func small(_ figure: WatchGlance.Figure) -> some View {
        let hue = figure.lit ? Hue.of(figure.node, way: now?.reading(figure.node)?.way ?? .resting) : Theme.ink
        return Button { choose(figure.node) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                NodeMark(node: figure.node, direction: figure.direction, size: 11, color: figure.lit ? hue : Theme.ink3)
                    .frame(width: 26, alignment: .leading)
                Text(figure.value)
                    .font(Theme.figure(16))
                    .foregroundStyle(hue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(figure.unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(figure.title), \(figure.value) \(figure.unit), \(figure.word)")
        .accessibilityIdentifier("watch.now.\(figure.node.rawValue)")
    }
}

/// The phone's live trace surface, small: three minutes, glowing only
/// while live. No magnitudes in a gutter: the round edge of the screen cuts
/// them, and the figure above says the value.
///
/// A horizontal drag reads it: the window holds still, the large figure
/// gives the reading under the finger, the lock-on marks it with its time,
/// and each reading crossed ticks. A drag that starts up or down is left to
/// the pages.
private struct TraceView: View {
    let trace: WatchTrace
    let live: Bool
    let zone: TimeZone
    @Binding var held: LiveSample?
    @State private var step = ScrubStep()
    @State private var frozenAtMs: Double?
    @State private var catchUp: (fromMs: Double, at: Date)?
    @State private var across: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let chart = ChartFrame(top: 4, bottom: 2, trailing: 0)
    /// A drag this long before it counts as across or along the pages.
    static let decideAfter: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let plot = Self.chart.plot(in: geo.size)
            ZStack {
                Color.clear
                if let frame = trace.frame {
                    LiveTraceSurface(frame: frame, look: WatchTrace.look(trace.node), live: live, chartFrame: Self.chart, frozenAtMs: frozenAtMs, catchUp: catchUp, axisSize: 8, paused: !live)
                    if let held, let i = frame.readings.firstIndex(of: held) {
                        LockOnMark(frame: frame, index: i, viewMs: viewMs(frame), look: WatchTrace.look(trace.node), zone: zone)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.decideAfter)
                    .onChanged { drag in
                        if across == nil { across = abs(drag.translation.width) > abs(drag.translation.height) }
                        guard across == true, let frame = trace.frame else { return }
                        if frozenAtMs == nil { frozenAtMs = viewMs(frame) }
                        move(to: drag.location.x, in: frame, size: geo.size)
                    }
                    .onEnded { _ in lift() }
            )
            .onAppear { trace.resize(plot.size) }
            .onChange(of: plot.size) { _, size in trace.resize(size) }
        }
        .sensoryFeedback(.selection, trigger: step.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: step.bumps)
        .accessibilityHidden(true)
    }

    /// The moment the window ends at: held under a finger, else now while
    /// live, else the newest reading.
    private func viewMs(_ frame: TraceFrame) -> Double {
        frozenAtMs ?? (live ? Date.now.timeIntervalSince1970 * 1000 : frame.series.nowMs)
    }

    private func move(to x: CGFloat, in frame: TraceFrame, size: CGSize) {
        let s = frame.series, plot = Self.chart.plot(in: size)
        guard s.ptPerMs > 0 else { return }
        let t = viewMs(frame) - Double((plot.width - s.inset - (x - plot.minX)) / s.ptPerMs)
        guard let i = SlotGrid.nearest(frame.times, to: t) else { return }
        step.move(to: i, landmark: frame.landmarks.contains(i))
        if held != frame.readings[i] { held = frame.readings[i] }
    }

    private func lift() {
        across = nil
        guard held != nil || frozenAtMs != nil else { return }
        if let frozenAtMs, live, !reduceMotion { catchUp = (frozenAtMs, .now) }
        frozenAtMs = nil
        held = nil
        step.lift()
    }
}

/// The lock-on over the reading under the finger: the rule, the dot with
/// its brackets, and its time in the inverse-video tag.
private struct LockOnMark: View {
    let frame: TraceFrame
    let index: Int
    let viewMs: Double
    let look: TraceLook
    let zone: TimeZone

    var body: some View {
        Canvas { g, size in
            let s = frame.series, r = frame.readings[index]
            let plot = TraceView.chart.plot(in: size)
            let px = 1 / max(g.environment.displayScale, 1)
            let x = ((plot.minX + s.x(r.t) - s.shift(at: viewMs)) / px).rounded() * px + px / 2
            let y = plot.minY + s.map.y(r.v)
            LockOn.rule(at: x, plot: plot, px: px, in: &g)
            LockOn.dot(at: CGPoint(x: x, y: y), color: r.v >= 0 ? look.up : look.down, in: &g)
            LockOn.tag(ZoneClock.of(zone).seconds(r.t), over: x, plot: plot, size: 10, in: &g, canvas: size)
        }
        .allowsHitTesting(false)
    }
}
