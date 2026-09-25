import FTWKit
import SwiftUI

/// The house and what flows through it, drawn from the same nodes the box's
/// own dashboard draws: solar top left, battery top right, grid bottom left,
/// the car bottom right, the house in the middle.
///
/// Dots move along a line only while readings are live. A cached or quiet
/// view holds still, because motion says power is flowing right now.
struct FlowDiagram: View {
    let readings: Flow.Readings
    let moving: Bool
    let tap: (Flow.Role) -> Void

    private static let height: CGFloat = 340

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(size: geo.size, nodes: readings.nodes)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
                    Canvas { canvas, _ in
                        draw(canvas, layout: layout, at: context.date.timeIntervalSinceReferenceDate)
                    }
                }
                .accessibilityHidden(true)

                Hub(loadKw: readings.loadKw, selfPoweredPct: readings.selfPoweredPctToday)
                    .position(layout.hub)
                    .onTapGesture { tap(.load) }

                ForEach(readings.nodes) { node in
                    Bubble(node: node)
                        .position(layout.points[node.id] ?? layout.hub)
                        .onTapGesture { if node.tappable { tap(node.role) } }
                }
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    /// Where each node sits. Several nodes in one corner stack toward the
    /// middle, the way a site with two inverters shows two suns.
    struct Layout {
        let hub: CGPoint
        let points: [String: CGPoint]

        init(size: CGSize, nodes: [Flow.Node]) {
            let w = size.width, h = size.height
            hub = CGPoint(x: w / 2, y: h / 2)
            var points = [String: CGPoint]()
            var counts = [String: Int]()
            for node in nodes {
                let key = "\(node.corner)"
                let n = counts[key, default: 0]
                counts[key] = n + 1
                let x: CGFloat = (node.corner == .topLeft || node.corner == .bottomLeft) ? w * 0.17 : w * 0.83
                let top = node.corner == .topLeft || node.corner == .topRight
                let y: CGFloat = top ? h * 0.16 + CGFloat(n) * 96 : h * 0.84 - CGFloat(n) * 96
                points[node.id] = CGPoint(x: x, y: y)
            }
            self.points = points
        }
    }

    private func draw(_ canvas: GraphicsContext, layout: Layout, at time: TimeInterval) {
        for node in readings.nodes {
            guard let from = layout.points[node.id] else { continue }
            var line = Path()
            line.move(to: from)
            line.addLine(to: layout.hub)
            let active = node.kw * 1000 > Flow.idleW
            let color = Theme.color(node.tone)
            canvas.stroke(line, with: .color(active ? color.opacity(0.45) : Theme.line), style: StrokeStyle(lineWidth: active ? 2 : 1.5, dash: active ? [] : [3, 5]))
            guard active, moving else { continue }
            // Speed grows with power but never races: a kettle and a car
            // charger are both readable at a glance.
            let speed = 0.25 + min(1.2, log10(1 + node.kw) * 0.9)
            let dots = 4
            for i in 0..<dots {
                var t = (time * speed + Double(i) / Double(dots)).truncatingRemainder(dividingBy: 1)
                if !node.toHub { t = 1 - t }
                let p = CGPoint(x: from.x + (layout.hub.x - from.x) * t, y: from.y + (layout.hub.y - from.y) * t)
                canvas.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
    }
}

/// The house in the middle: everything the home is using right now.
private struct Hub: View {
    let loadKw: Double
    let selfPoweredPct: Double?

    var body: some View {
        let parts = PowerFormat.parts(loadKw * 1000)
        VStack(spacing: 2) {
            Image(systemName: "house.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            (Text(parts.text).font(Theme.number(22, weight: .bold)) + Text(" \(parts.unit)").font(.caption))
                .foregroundStyle(Theme.fg)
            Text("HOME").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.fgDim)
            if let pct = selfPoweredPct {
                Text("\(Int(pct.rounded()))% self-powered today")
                    .font(.caption2)
                    .foregroundStyle(Theme.fgMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 118, height: 118)
        .background(Circle().fill(Theme.surfaceElevated))
        .overlay(Circle().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Home using \(parts.joined)")
    }
}

/// One node: a title, a magnitude with a direction word, and whatever
/// else the box said about it.
private struct Bubble: View {
    let node: Flow.Node

    var body: some View {
        let parts = PowerFormat.parts(node.kw * 1000)
        let color = Theme.color(node.tone)
        VStack(spacing: 1) {
            Text(node.title).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(Theme.fgDim)
            if let name = node.name {
                Text(name).font(.caption2).foregroundStyle(Theme.fgMuted).lineLimit(1)
            }
            (Text(parts.text).font(Theme.number(17, weight: .bold)) + Text(" \(parts.unit)").font(.caption2))
                .foregroundStyle(color)
            if let soc = node.socPct {
                SocBar(pct: soc)
            }
            if !node.sub.isEmpty {
                Text(node.sub).font(.caption2).foregroundStyle(Theme.fgDim)
            }
            if !node.dailyParts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(node.dailyParts.enumerated()), id: \.offset) { _, part in
                        Text(part.text).font(Theme.number(10, weight: .regular)).foregroundStyle(Theme.color(part.tone))
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 104)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(node.tappable ? .isButton : [])
    }
}

private struct SocBar: View {
    let pct: Double

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(Theme.storage).frame(width: geo.size.width * min(1, max(0, pct / 100)))
                }
            }
            .frame(width: 40, height: 5)
            Text("\(Int(pct))%").font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.fg)
        }
    }
}
