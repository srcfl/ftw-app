#if DEBUG && targetEnvironment(simulator)
import FTWShared
import SwiftUI

struct DistributionEnergyPort {
    let route: DistributionScreen
    let title, symbol: String
    let power: Double
    let outward: Bool
    var color: Color { route == .grid ? DistributionStyle.green : DistributionStyle.gold }

    static func ports(_ flow: EnergyFlowBalance) -> [Self] {
        var ports: [Self] = []
        if flow.solar > 0.025 { ports.append(.init(route: .solar, title: "Från solen", symbol: "sun.max", power: flow.solar, outward: false)) }
        if abs(flow.grid) > 0.025 { ports.append(.init(route: .grid, title: flow.grid > 0 ? "Från nätet" : "Till nätet", symbol: "powerplug", power: abs(flow.grid), outward: flow.grid < 0)) }
        if flow.battery < -0.025 { ports.append(.init(route: .battery, title: "Från batteriet", symbol: "battery.75percent", power: -flow.battery, outward: false)) }
        return ports
    }
}

struct DistributionInlets: View {
    let flow: EnergyFlowBalance
    let finger, origin: CGPoint
    let grip: Double
    let frozen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        let moving = visible && !reduceMotion && !frozen && scenePhase == .active
        HStack(alignment: .top, spacing: 0) {
            ForEach(DistributionEnergyPort.ports(flow), id: \.route) { port in
                NavigationLink(value: port.route) {
                    VStack(spacing: 5) {
                        Label(port.title, systemImage: port.symbol).font(.subheadline).lineLimit(2)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(DistributionStyle.number(port.power)).font(.system(size: 27, weight: .medium))
                            Text("kW").font(.system(size: 15))
                            Image(systemName: port.outward ? "arrow.up" : "arrow.down").font(.system(size: 12, weight: .medium))
                        }.monospacedDigit().contentTransition(.numericText(value: port.power))
                        Spacer(minLength: 74)
                    }
                    .foregroundStyle(DistributionStyle.ink).frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.top, 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(port.title), \(DistributionStyle.number(port.power)) kilowatt, \(port.outward ? "ut ur hemmet" : "in i hemmet")")
                .accessibilityIdentifier("distribution.inlet.\(port.route.rawValue)")
            }
        }
        .frame(minHeight: 142)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { clock in
                DistributionInletInk(flow: flow, time: moving ? clock.date.timeIntervalSinceReferenceDate : 0,
                                     finger: finger, origin: origin, grip: grip)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .onAppear { visible = true }.onDisappear { visible = false }
        .accessibilityElement(children: .contain)
    }
}

nonisolated struct DistributionInletInk: View, Animatable {
    let flow: EnergyFlowBalance
    let time: Double
    var finger, origin: CGPoint
    var grip: Double
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { .init(.init(Double(finger.x), Double(finger.y)), grip) }
        set { finger = CGPoint(x: newValue.first.first, y: newValue.first.second); grip = newValue.second }
    }

    @MainActor var body: some View {
        Canvas { context, size in
            let ports = DistributionEnergyPort.ports(flow)
            for (i, port) in ports.enumerated() {
                let x = size.width * (Double(i) + 0.5) / Double(ports.count)
                let top = CGPoint(x: x, y: 69), bottom = CGPoint(x: x, y: size.height + 24)
                let points = EnergyStreamline(from: top, control1: CGPoint(x: x - 9, y: 94), control2: CGPoint(x: x + 12, y: size.height - 20), to: bottom,
                                              finger: finger, origin: origin, strength: grip, radius: 37, side: i.isMultiple(of: 2) ? 1 : -1).points
                let directed = port.outward ? Array(points.reversed()) : points
                DistributionFluidInk.channel(directed, power: port.power, time: time, color: port.color, context: context, drains: port.outward)
                DistributionFluidInk.well(at: port.outward ? top : bottom, power: port.power, time: time,
                                          color: port.color, draining: port.outward, context: context)
            }
            DistributionFluidInk.contact(finger: finger, strength: grip, context: context)
        }
    }
}

struct DistributionFluidInk: View {
    let layout: EnergyPartition
    let flow: EnergyFlowBalance
    let time: Double
    let drag: CGSize
    let touch: CGPoint
    let finger: CGPoint
    let grip: Double

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let origin = CGPoint(x: touch.x * w, y: touch.y * h)
            let ports = DistributionEnergyPort.ports(flow)
            let mouth = CGPoint(x: w * 0.47, y: 78)
            let outlets = [CGPoint(x: -30, y: layout.centers[0].y), CGPoint(x: w + 30, y: layout.centers[1].y),
                           CGPoint(x: w + 30, y: layout.centers[2].y)]
            if time > 0 {
                for i in 0..<3 where layout.shares[i] > 0.0001 {
                    let center = layout.centers[i]
                    let points = EnergyStreamline(from: mouth, control1: CGPoint(x: center.x, y: max(85, center.y * 0.48)),
                                                  control2: CGPoint(x: center.x, y: center.y), to: outlets[i],
                                                  finger: finger, origin: origin, strength: grip, radius: 42,
                                                  side: i.isMultiple(of: 2) ? 1 : -1).points
                    var ink = context
                    ink.clip(to: Self.region(layout, index: i), style: FillStyle(eoFill: true))
                    Self.paint(Self.path(points), power: layout.shares[i] * layout.total, time: time + Double(i) * 1.7,
                               color: DistributionStyle.eye, context: ink)
                    Self.well(at: center, power: layout.shares[i] * layout.total, time: time, color: DistributionStyle.colors[i], draining: false, context: ink)
                }
            }
            for (i, port) in ports.enumerated() {
                let x = w * (Double(i) + 0.5) / Double(ports.count)
                let start = port.outward ? layout.centers[3] : CGPoint(x: x, y: -24)
                let end = port.outward ? CGPoint(x: x, y: -24) : mouth
                let points = EnergyStreamline(from: start,
                                              control1: port.outward ? CGPoint(x: w * 0.97, y: h * 0.7) : CGPoint(x: x, y: 38),
                                              control2: port.outward ? CGPoint(x: w * 0.98, y: 25) : CGPoint(x: mouth.x + (x - mouth.x) * 0.45, y: 58),
                                              to: end, finger: finger, origin: origin, strength: grip, radius: 40,
                                              side: i.isMultiple(of: 2) ? 1 : -1).points
                Self.channel(points, power: port.power, time: time, color: port.color, context: context, drains: port.outward)
                if port.outward { Self.well(at: start, power: port.power, time: time, color: port.color, draining: true, context: context) }
            }
            var edges = Self.path(Array(layout.polygons[0].dropFirst().dropLast()))
            if layout.shares[1] > 0, layout.shares[2] + layout.shares[3] > 0 { edges.addPath(Self.path(Array(layout.polygons[1].dropFirst(2).prefix(65)))) }
            if layout.shares[2] > 0, layout.shares[3] > 0 { edges.addPath(Self.path(Array(layout.polygons[2].dropFirst(2).prefix(65)))) }
            var edgeInk = context
            edgeInk.addFilter(.blur(radius: 5))
            edgeInk.stroke(edges, with: .color(DistributionStyle.eye.opacity(0.27)), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            Self.contact(finger: finger, strength: grip, context: context)
        }
    }

    nonisolated static func channel(_ points: [CGPoint], power: Double, time: Double, color: Color, context: GraphicsContext, drains: Bool) {
        guard points.count > 2 else { return }
        let width = 7 + min(20, sqrt(power) * 6)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in points.enumerated() {
            let before = points[max(0, i - 1)], after = points[min(points.count - 1, i + 1)]
            let length = max(0.001, hypot(after.x - before.x, after.y - before.y))
            let t = Double(i) / Double(points.count - 1)
            let flare = drains ? 1.3 - t * 0.7 : 0.6 + t * 0.7
            let breath = time > 0 ? 1 + sin(t * 9 - time * 2.5) * 0.065 : 1
            let r = width * flare * breath
            let nx = -(after.y - before.y) / length, ny = (after.x - before.x) / length
            left.append(CGPoint(x: p.x + nx * r, y: p.y + ny * r))
            right.append(CGPoint(x: p.x - nx * r, y: p.y - ny * r))
        }
        var ink = context
        ink.addFilter(.blur(radius: 3.5))
        ink.fill(path(left + right.reversed(), close: true), with: .color(color.opacity(0.48)))
        let center = path(points)
        ink.stroke(center, with: .color(color.opacity(0.2)), style: StrokeStyle(lineWidth: width * 1.2, lineCap: .round, lineJoin: .round))
        if time > 0 { paint(center, power: power, time: time, color: .white, context: context, scale: 0.7) }
    }

    nonisolated static func well(at center: CGPoint, power: Double, time: Double, color: Color, draining: Bool, context: GraphicsContext) {
        guard time > 0 else { return }
        let cycle = (time * (0.22 + sqrt(power) * 0.06)).truncatingRemainder(dividingBy: 1)
        let progress = draining ? 1 - cycle : cycle
        let radius = 18 + progress * 37
        let ellipse = CGRect(x: center.x - radius, y: center.y - radius * 0.35, width: radius * 2, height: radius * 0.7)
        var ink = context
        ink.addFilter(.blur(radius: 8))
        ink.stroke(Path(ellipseIn: ellipse), with: .color(color.opacity((1 - progress) * 0.3)), lineWidth: 12)
    }

    nonisolated static func contact(finger: CGPoint, strength: Double, context: GraphicsContext) {
        let amount = max(0, min(1, strength))
        guard amount > 0.001 else { return }
        var ink = context
        ink.addFilter(.blur(radius: 3))
        let r = 32.0, rect = CGRect(x: finger.x - r, y: finger.y - r, width: r * 2, height: r * 2)
        ink.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.black.opacity(amount * 0.10), .clear]), center: finger, startRadius: 0, endRadius: r))
        ink.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(amount * 0.48)), lineWidth: 2.5)
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
            ink.addFilter(.blur(radius: 7))
            ink.stroke(path.trimmedPath(from: tail, to: end), with: .color(color.opacity(0.38 * fade)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
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
