import FTWShared
import SwiftUI

/// Now, alive, on one screen: the status line, one node's figure large,
/// its live trace, and the other nodes small. A tap on a small one makes
/// it the traced one. The trace and the figures glow only while the phone
/// passes on live frames; anything else is ink with the minute it was read.
/// How the home is run sits behind the toolbar's button.
struct NowPage: View {
    let model: WatchModel
    /// Always On redraws once a minute: a figure lit then would show an old
    /// reading as live, so nothing glows while the wrist is down.
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        let lit = model.lit && !dim
        let figures = WatchGlance.figures(model.now?.value, lit: lit)
        let hero = figures.first { $0.node == model.trace.node } ?? figures.first
        let rest = figures.filter { $0.node != hero?.node }
        OnePage {
            nowStack(lit: lit, figures: figures, hero: hero, rest: rest)
        }
        // A home without the traced node (no car, no sun) traces its first.
        .onChange(of: figures.map(\.node), initial: true) { _, nodes in
            if let first = nodes.first, !nodes.contains(model.trace.node) { model.trace.follow(first) }
        }
        .navigationTitle(WatchWord.nowTitle.text)
        .toolbar { modeButton }
    }

    private func nowStack(lit: Bool, figures: [WatchGlance.Figure], hero: WatchGlance.Figure?, rest: [WatchGlance.Figure]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            StatusLine(status: WatchGlance.status(model.now, lit: lit, demo: model.context?.isDemo == true, zone: model.zone))
                // Clear of the page dots at the right edge.
                .padding(.trailing, 10)
            if let hero {
                HeroFigure(figure: hero, way: model.now?.value.reading(hero.node)?.way ?? .resting)
            }
            // Whatever height is left, so Now fits 41 mm as well as 46.
            TraceView(trace: model.trace, live: lit)
                .frame(minHeight: 24, maxHeight: .infinity)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: rest.count, by: 2)), id: \.self) { i in
                    GridRow {
                        SmallFigure(figure: rest[i], way: model.now?.value.reading(rest[i].node)?.way ?? .resting) { model.follow(rest[i].node) }
                        if i + 1 < rest.count {
                            SmallFigure(figure: rest[i + 1], way: model.now?.value.reading(rest[i + 1].node)?.way ?? .resting) { model.follow(rest[i + 1].node) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ToolbarContentBuilder private var modeButton: some ToolbarContent {
        if let modes = model.context?.modes, modes.label != nil {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    ModeList(model: model, modes: modes)
                } label: {
                    Image(systemName: model.sending(WatchModel.modeTarget) ? "ellipsis" : "slider.horizontal.3")
                }
                .accessibilityLabel(WatchWord.mode.text)
                .accessibilityValue(modes.label ?? "")
                .accessibilityIdentifier("watch.mode")
            }
        }
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

/// The traced node: its glyph, the figure large, and its word.
private struct HeroFigure: View {
    let figure: WatchGlance.Figure
    let way: WatchNow.Way

    var body: some View {
        let hue = figure.lit ? Hue.of(figure.node, way: way) : Theme.ink
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: NodeGlyph.name(figure.node))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(figure.lit ? hue : Theme.ink2)
            Text(figure.value)
                .font(Theme.figure(32))
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

/// Another node, small: glyph and figure. A tap traces it.
private struct SmallFigure: View {
    let figure: WatchGlance.Figure
    let way: WatchNow.Way
    let choose: () -> Void

    var body: some View {
        let hue = figure.lit ? Hue.of(figure.node, way: way) : Theme.ink
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: NodeGlyph.name(figure.node))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(figure.lit ? hue : Theme.ink3)
                    .frame(width: 13)
                Text(figure.value)
                    .font(Theme.figure(15))
                    .foregroundStyle(hue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(figure.unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
private struct TraceView: View {
    let trace: WatchTrace
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            let chart = ChartFrame(top: 4, bottom: 2, trailing: 0)
            let plot = chart.plot(in: geo.size)
            ZStack {
                Color.clear
                if let frame = trace.frame {
                    LiveTraceSurface(frame: frame, look: WatchTrace.look(trace.node), live: live, chartFrame: chart, axisSize: 8, paused: !live)
                }
            }
            .onAppear { trace.resize(plot.size) }
            .onChange(of: plot.size) { _, size in trace.resize(size) }
        }
        .accessibilityHidden(true)
    }
}
