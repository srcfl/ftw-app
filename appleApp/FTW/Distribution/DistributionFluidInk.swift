#if DEBUG && targetEnvironment(simulator)
import FTWShared
import SwiftUI

struct DistributionInlets: View {
    let flow: EnergyFlowBalance

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if flow.solar > 0.025 { port(.solar, title: "Från solen", symbol: "sun.max", power: flow.solar, color: DistributionStyle.gold) }
            if flow.grid > 0.025 { port(.grid, title: "Från nätet", symbol: "powerplug", power: flow.grid, color: DistributionStyle.green) }
            if flow.battery < -0.025 { port(.battery, title: "Från batteriet", symbol: "battery.75percent", power: -flow.battery, color: DistributionStyle.gold) }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private func port(_ route: DistributionScreen, title: String, symbol: String, power: Double, color: Color) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 5) {
                Label(title, systemImage: symbol).font(.subheadline).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(DistributionStyle.number(power)).font(.system(size: 34, weight: .medium))
                    Text("kW").font(.system(size: 17))
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .medium))
                }.monospacedDigit().contentTransition(.numericText(value: power))
            }
            .foregroundStyle(DistributionStyle.ink).frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
            .background(RadialGradient(colors: [color.opacity(0.22), color.opacity(0)], center: .bottom, startRadius: 0, endRadius: 140))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(DistributionStyle.number(power)) kilowatt, in i hemmet")
        .accessibilityIdentifier("distribution.inlet.\(route.rawValue)")
    }
}

/// Light travels along a continuous ribbon. Every outlet has its own speed
/// and width; a touch bends the ribbon with the material around it.
struct DistributionFluidInk: View {
    let layout: EnergyPartition
    let flow: EnergyFlowBalance
    let time: Double
    let drag: CGSize
    let touch: CGPoint
    let grabbing: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let outlets = [CGPoint(x: -30, y: layout.centers[0].y),
                           CGPoint(x: w + 30, y: layout.centers[1].y),
                           CGPoint(x: w + 30, y: layout.centers[2].y),
                           CGPoint(x: w * 0.88, y: h + 35)]
            let entryX = flow.solar > 0.025 && flow.grid > 0.025 ? w * 0.42 : w * 0.5
            if time > 0 {
                for i in 0..<4 where layout.shares[i] > 0.0001 {
                    let center = layout.centers[i]
                    var ribbon = Path()
                    ribbon.move(to: CGPoint(x: entryX, y: -45))
                    ribbon.addCurve(to: outlets[i],
                                    control1: CGPoint(x: center.x + drag.width * 65, y: max(50, center.y * 0.42) + drag.height * 35),
                                    control2: CGPoint(x: center.x + drag.width * 38, y: center.y + drag.height * 45))
                    var ink = context
                    ink.clip(to: Self.region(layout, index: i), style: FillStyle(eoFill: true))
                    Self.paint(ribbon, power: layout.shares[i] * layout.total, time: time + Double(i) * 1.7,
                               color: DistributionStyle.eye, context: ink)
                }
                // The necks start above the field: they enter from the source
                // labels, while the four ribbons leave through the outlets.
                var sources: [(Double, Color)] = []
                if flow.solar > 0.025 { sources.append((flow.solar, DistributionStyle.gold)) }
                if flow.grid > 0.025 { sources.append((flow.grid, DistributionStyle.green)) }
                if flow.battery < -0.025 { sources.append((-flow.battery, DistributionStyle.gold)) }
                for (i, source) in sources.enumerated() {
                    let x = w * (Double(i) + 0.5) / Double(sources.count)
                    var neck = Path()
                    neck.move(to: CGPoint(x: x, y: -22))
                    neck.addCurve(to: CGPoint(x: x + drag.width * 22, y: 90),
                                  control1: CGPoint(x: x, y: 20), control2: CGPoint(x: x + drag.width * 28, y: 52))
                    var ink = context
                    ink.addFilter(.blur(radius: 5))
                    ink.stroke(neck, with: .linearGradient(Gradient(colors: [source.1.opacity(0.7), source.1.opacity(0)]),
                                                         startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x, y: 90)),
                               style: StrokeStyle(lineWidth: 10 + sqrt(source.0) * 10, lineCap: .round))
                    Self.paint(neck, power: source.0, time: time, color: DistributionStyle.eye, context: context, scale: 0.7)
                }
            }
            // A broad, feathered meniscus replaces a hard outline.
            var edges = Self.path(Array(layout.polygons[0].dropFirst().dropLast()))
            if layout.shares[1] > 0, layout.shares[2] + layout.shares[3] > 0 {
                edges.addPath(Self.path(Array(layout.polygons[1].dropFirst(2).prefix(65))))
            }
            if layout.shares[2] > 0, layout.shares[3] > 0 {
                edges.addPath(Self.path(Array(layout.polygons[2].dropFirst(2).prefix(65))))
            }
            var edgeInk = context
            edgeInk.addFilter(.blur(radius: 5))
            edgeInk.stroke(edges, with: .color(DistributionStyle.eye.opacity(0.27)), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))

            if grabbing {
                let origin = CGPoint(x: touch.x * w, y: touch.y * h)
                let finger = CGPoint(x: origin.x + drag.width * w * 0.27, y: origin.y + drag.height * h * 0.25)
                var stretch = Path()
                stretch.move(to: origin)
                stretch.addQuadCurve(to: finger, control: CGPoint(x: finger.x, y: origin.y))
                var grip = context
                grip.addFilter(.blur(radius: 13))
                grip.stroke(stretch, with: .color(DistributionStyle.eye.opacity(0.28)), style: StrokeStyle(lineWidth: 48, lineCap: .round))
                let mound = CGRect(x: finger.x - 55, y: finger.y - 55, width: 110, height: 110)
                grip.fill(Path(ellipseIn: mound), with: .radialGradient(Gradient(colors: [DistributionStyle.eye.opacity(0.4), .clear]),
                                                                     center: finger, startRadius: 0, endRadius: 55))
            }
        }
    }

    nonisolated static func paint(_ path: Path, power: Double, time: Double, color: Color, context: GraphicsContext, scale: Double = 1) {
        let speed = 0.18 + min(0.4, sqrt(power) * 0.11)
        let width = (12 + min(32, sqrt(power) * 14)) * scale
        for offset in [0.0, 0.75] {
            let head = (time * speed + offset).truncatingRemainder(dividingBy: 1.5)
            let tail = max(0, head - 0.46), end = min(1, head)
            guard tail < end else { continue }
            let fade = max(0, min(1, head / 0.16, (1.5 - head) / 0.25))
            var ink = context
            ink.addFilter(.blur(radius: 8))
            ink.stroke(path.trimmedPath(from: tail, to: end), with: .color(color.opacity(0.33 * fade)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

    private nonisolated static func region(_ layout: EnergyPartition, index: Int) -> Path {
        var p = path(layout.polygons[index], close: true)
        if index == 2 || index == 3 { p.addPath(path(layout.polygons[index - 1], close: true)) }
        return p
    }

    private nonisolated static func path(_ points: [CGPoint], close: Bool = false) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for point in points.dropFirst() { p.addLine(to: point) }
            if close { p.closeSubpath() }
        }
    }
}
#endif
