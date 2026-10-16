#if DEBUG && targetEnvironment(simulator)
import FTWShared
import SwiftUI

struct DistributionNow: View {
    let namespace: Namespace.ID
    @Environment(DistributionModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            ScrollView {
                DistributionSite(namespace: namespace, showsLabels: false).frame(height: 340)
                    .accessibilityHidden(true).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 28) {
                    Text("Fastighetens energi").font(.title2)
                    ForEach(EnergySiteLayout.Part.allCases, id: \.rawValue) { part in
                        let info = DistributionSiteInfo(part: part, flow: model.flow, level: model.level)
                        NavigationLink(value: info.route) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(info.title).font(.headline)
                                Text(info.reading).font(.title2)
                                Text(info.detail).font(.body)
                            }.foregroundStyle(DistributionStyle.ink)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("distribution.accessible.\(info.route.rawValue)")
                    }
                }.padding(24)
            }
        } else {
            DistributionSite(namespace: namespace)
        }
    }
}

private struct DistributionSiteInfo {
    let part: EnergySiteLayout.Part
    let flow: EnergyFlowBalance
    let level: Int
    var route: DistributionScreen {
        switch part { case .solar: .solar; case .home: .home; case .car: .car; case .battery: .battery; case .grid: .grid }
    }
    var title: String {
        switch part { case .solar: "Solen"; case .home: "Hemmet"; case .car: "Bilen"; case .battery: "Hembatteriet"; case .grid: "Nätanslutningen" }
    }
    var power: Double {
        switch part { case .solar: flow.solar; case .home: flow.home; case .car: flow.car; case .battery: abs(flow.battery); case .grid: abs(flow.grid) }
    }
    var reading: String { part == .battery ? "68 %" : "\(DistributionStyle.number(power)) kW" }
    var detail: String {
        switch part {
        case .solar: flow.solar > 0.025 ? "Tillför energi" : "Ingen produktion"
        case .home: "Använder energi"
        case .car: "\(level) % · \(power > 0.025 ? "laddar" : "pausad")"
        case .battery: flow.battery > 0.025 ? "+\(DistributionStyle.number(power)) kW · lagrar" : flow.battery < -0.025 ? "−\(DistributionStyle.number(power)) kW · ger energi" : "Vilar · 9,5 kWh lagrat"
        case .grid: flow.grid > 0.025 ? "Från nätet · in i fastigheten" : flow.grid < -0.025 ? "Till nätet · ut ur fastigheten" : "I balans · inget utbyte"
        }
    }
    var color: Color {
        switch part { case .solar: DistributionStyle.gold; case .home: DistributionStyle.home; case .car: DistributionStyle.purple; case .battery: DistributionStyle.cyan; case .grid: DistributionStyle.green }
    }
    var ink: Color {
        switch part { case .solar: DistributionStyle.goldInk; case .home: DistributionStyle.homeInk; case .car: DistributionStyle.purpleInk; case .battery: DistributionStyle.cyanInk; case .grid: DistributionStyle.ink }
    }
}

private struct DistributionSite: View {
    let namespace: Namespace.ID
    var showsLabels = true
    @Environment(DistributionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var finger = CGPoint.zero
    @State private var origin = CGPoint.zero
    @State private var grip = 0.0
    @State private var grabbing = false
    @State private var grabs = 0
    @State private var visible = false
    @State private var heldTime = Date.now.timeIntervalSinceReferenceDate

    var body: some View {
        GeometryReader { proxy in
            let layout = EnergySiteLayout(size: proxy.size, flow: model.flow)
            let moving = visible && showsLabels && !model.frozen && !reduceMotion && scenePhase == .active
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { clock in
                    DistributionSiteInk(flow: model.flow, time: moving ? clock.date.timeIntervalSinceReferenceDate : heldTime,
                                        moving: moving, finger: finger, origin: origin, grip: grip)
                        .animation(moving ? DistributionStyle.motion : nil, value: [model.flow.solar, model.flow.grid, model.flow.battery, model.flow.car, model.flow.home])
                }.allowsHitTesting(false).accessibilityHidden(true)
                if showsLabels {
                    ForEach(EnergySiteLayout.Part.allCases, id: \.rawValue) { part in
                        siteLabel(part, layout: layout)
                    }
                }
                DistributionRobot(happy: model.happy, frozen: model.frozen || !showsLabels, gaze: grabbing ? (finger.x - origin.x) / 90 : 0)
                    .frame(width: 88)
                    .rotationEffect(.degrees(grabbing ? max(-12, min(12, (finger.x - origin.x) / 10)) : 0))
                    .position(x: layout.junction.x + 4, y: layout.junction.y + 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dra i energin").font(.system(size: 12, weight: .medium))
                    Text("Tryck för mer").font(.system(size: 11))
                }.foregroundStyle(DistributionStyle.muted)
                    .position(x: proxy.size.width * 0.22, y: proxy.size.height * 0.775)
                    .allowsHitTesting(false).accessibilityHidden(true).opacity(showsLabels ? 1 : 0)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !grabbing {
                        grabbing = true; grip = 1; grabs += 1; model.stop()
                        origin = value.startLocation
                    }
                    finger = value.location
                }
                .onEnded { value in
                    let distance = max(35, hypot(value.translation.width, value.translation.height))
                    let speed = min(4, hypot(value.velocity.width, value.velocity.height) / distance)
                    withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 36, damping: 6.8, initialVelocity: -speed)) {
                        grip = 0; grabbing = false
                    }
                }, including: model.frozen ? .none : .all)
            .sensoryFeedback(.impact(weight: .light), trigger: grabs)
            .accessibilityElement(children: .contain)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; grip = 0; grabbing = false }
        .onChange(of: model.frozen) { _, frozen in
            if frozen { heldTime = Date.now.timeIntervalSinceReferenceDate; grip = 0; grabbing = false }
        }
    }

    private func siteLabel(_ part: EnergySiteLayout.Part, layout: EnergySiteLayout) -> some View {
        let info = DistributionSiteInfo(part: part, flow: model.flow, level: model.level)
        return NavigationLink(value: info.route) {
            VStack(spacing: part == .grid ? 5 : 4) {
                Text(info.title).font(.system(size: part == .grid ? 12 : 15, weight: .medium))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if part == .grid, abs(model.flow.grid) > 0.025 {
                        Image(systemName: model.flow.grid > 0 ? "arrow.up" : "arrow.down").font(.system(size: 18, weight: .medium))
                    }
                    if part == .battery {
                        Text("68").font(.system(size: 38, weight: .regular))
                        Text("%").font(.system(size: 19))
                    } else {
                        Text(DistributionStyle.number(info.power)).font(.system(size: part == .solar ? 40 : part == .grid ? 31 : 32, weight: .regular))
                        Text("kW").font(.system(size: 16))
                    }
                }.monospacedDigit().contentTransition(.numericText(value: info.power))
                Text(info.detail).font(.system(size: part == .grid ? 11 : 10.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center).foregroundStyle(info.ink)
            .frame(width: part == .grid ? 285 : part == .battery ? 168 : 144)
            .padding(.vertical, 8).contentShape(Ellipse())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: info.route, in: namespace)
        .accessibilityLabel("\(info.title), \(info.reading), \(info.detail)")
        .accessibilityIdentifier("distribution.field.\(info.route.rawValue)")
        .position(layout.center(part))
    }
}

/// The whole viewport is material. There is no chart rectangle, source header
/// or second grid node. Power changes its volume and the light's direction.
private nonisolated struct DistributionSiteInk: View, Animatable {
    var flow: EnergyFlowBalance
    let time: Double
    let moving: Bool
    var finger, origin: CGPoint
    var grip: Double
    typealias Pair = AnimatablePair<Double, Double>
    typealias Powers = AnimatablePair<AnimatablePair<Pair, Pair>, Double>
    var animatableData: AnimatablePair<Powers, AnimatablePair<Pair, Double>> {
        get { .init(.init(.init(.init(flow.solar, flow.grid), .init(flow.battery, flow.car)), flow.home), .init(.init(finger.x, finger.y), grip)) }
        set {
            let p = newValue.first
            flow = .init(solar: p.first.first.first, grid: p.first.first.second, battery: p.first.second.first,
                         car: p.first.second.second, home: p.second)
            finger = CGPoint(x: newValue.second.first.first, y: newValue.second.first.second); grip = newValue.second.second
        }
    }

    @MainActor var body: some View {
        Canvas { context, size in
            let layout = EnergySiteLayout(size: size, flow: flow)
            let t = time, wave = moving ? time : 0
            let parts: [EnergySiteLayout.Part] = [.home, .solar, .car, .battery]
            var contours: [EnergySiteLayout.Part: Path] = [:]
            for part in parts {
                contours[part] = Self.closed(layout.contour(part, time: t, finger: finger, origin: origin, grip: grip))
            }
            // A single soft body joins all parts; its border never makes a box.
            let body = Self.body(size, time: t)
            var shadow = context
            shadow.addFilter(.blur(radius: 18))
            shadow.fill(body.offsetBy(dx: 0, dy: 9), with: .color(DistributionStyle.homeInk.opacity(0.09)))
            context.fill(body, with: .linearGradient(Gradient(colors: [DistributionStyle.home.opacity(0.64), DistributionStyle.raised.opacity(0.7)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

            // The sole grid throat belongs to the site, not to a second region.
            let grid = layout.stream(.grid, finger: finger, origin: origin, grip: grip, time: wave)
            for part in parts {
                guard let shape = contours[part] else { continue }
                let info = DistributionSiteInfo(part: part, flow: flow, level: 62)
                let center = layout.center(part), radius = layout.radii(part)
                var ink = context
                ink.addFilter(.blur(radius: 2.8))
                let active = abs(layout.signedPower(part)) > 0.025
                let opacity = part == .solar && !active ? 0.16 : 0.94
                ink.fill(shape, with: .radialGradient(Gradient(stops: [
                    .init(color: info.color.opacity(opacity * 0.55), location: 0),
                    .init(color: info.color.opacity(opacity), location: 0.65),
                    .init(color: info.color.opacity(opacity * 0.46), location: 1)
                ]), center: CGPoint(x: center.x - radius.width * 0.22, y: center.y - radius.height * 0.24), startRadius: 0, endRadius: max(radius.width, radius.height) * 1.2))
                var rim = context
                rim.addFilter(.blur(radius: 5))
                rim.stroke(shape, with: .color(DistributionStyle.eye.opacity(0.22)), lineWidth: 9)
            }

            Self.ribbon(grid, width: 18 + sqrt(abs(flow.grid)) * 12, color: DistributionStyle.green,
                        power: abs(flow.grid), time: wave, context: context, opacity: 0.48)

            // Sunlight grows into the site as broad, warm material, without a sun icon.
            let solar = layout.stream(.solar, finger: finger, origin: origin, grip: grip, time: wave)
            if flow.solar > 0.025 {
                Self.ribbon(solar, width: 18 + sqrt(flow.solar) * 17, color: DistributionStyle.gold,
                            power: flow.solar, time: wave, context: context, opacity: 0.55)
            }
            for part in [EnergySiteLayout.Part.home, .car, .battery] where abs(layout.signedPower(part)) > 0.025 {
                let info = DistributionSiteInfo(part: part, flow: flow, level: 62)
                let points = layout.stream(part, finger: finger, origin: origin, grip: grip, time: wave)
                Self.ribbon(points, width: 12 + sqrt(info.power) * 14, color: info.color,
                            power: info.power, time: wave, context: context, opacity: 0.52)
            }

            if let battery = contours[.battery] {
                Self.batteryLevel(battery, layout: layout, time: t, context: context)
            }
            if moving {
                for part in parts where abs(layout.signedPower(part)) > 0.025 {
                    let draining = layout.signedPower(part) < 0
                    DistributionFluidInk.well(at: layout.center(part), power: abs(layout.signedPower(part)), time: t,
                                              color: DistributionStyle.eye, draining: draining, context: context)
                }
            }
            DistributionFluidInk.contact(finger: finger, strength: grip, context: context)
        }
        .animation(moving ? DistributionStyle.motion : nil, value: [flow.solar, flow.grid, flow.battery, flow.car, flow.home])
    }

    @MainActor private static func batteryLevel(_ shape: Path, layout: EnergySiteLayout, time: Double, context: GraphicsContext) {
        let c = layout.center(.battery), r = layout.radii(.battery)
        let y = c.y + r.height * (1 - 0.68 * 2)
        var level = Path()
        level.move(to: CGPoint(x: c.x - r.width * 1.4, y: y))
        level.addCurve(to: CGPoint(x: c.x + r.width * 1.4, y: y + 5),
                       control1: CGPoint(x: c.x - r.width * 0.3, y: y - 15 + sin(time * 0.8) * 5),
                       control2: CGPoint(x: c.x + r.width * 0.4, y: y + 18 - sin(time * 0.8) * 5))
        level.addLine(to: CGPoint(x: c.x + r.width * 1.4, y: c.y + r.height * 1.4))
        level.addLine(to: CGPoint(x: c.x - r.width * 1.4, y: c.y + r.height * 1.4)); level.closeSubpath()
        var ink = context
        ink.clip(to: shape)
        ink.addFilter(.blur(radius: 5))
        ink.fill(level, with: .linearGradient(Gradient(colors: [DistributionStyle.cyan.opacity(0.05), DistributionStyle.cyan.opacity(0.6)]), startPoint: CGPoint(x: c.x, y: y), endPoint: CGPoint(x: c.x, y: c.y + r.height)))
        ink.stroke(level, with: .color(DistributionStyle.eye.opacity(0.25)), lineWidth: 8)
    }

    @MainActor private static func ribbon(_ points: [CGPoint], width: Double, color: Color, power: Double,
                                         time: Double, context: GraphicsContext, opacity: Double) {
        let path = Self.open(points)
        var ink = context
        ink.addFilter(.blur(radius: 10))
        ink.stroke(path, with: .color(color.opacity(opacity * 0.38)), style: StrokeStyle(lineWidth: width * 2.8, lineCap: .round, lineJoin: .round))
        ink.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width * 1.55, lineCap: .round, lineJoin: .round))
        if time > 0, power > 0.025 {
            DistributionFluidInk.paint(path, power: power, time: time, color: DistributionStyle.eye, context: context, scale: 1.65)
        }
    }

    private static func body(_ size: CGSize, time: Double) -> Path {
        let w = size.width, h = size.height, drift = sin(time * 0.4) * 8
        return Path { p in
            p.move(to: CGPoint(x: w * 0.21, y: h * 0.05))
            p.addCurve(to: CGPoint(x: w * 1.06, y: h * 0.30), control1: CGPoint(x: w * 0.70, y: -h * 0.10), control2: CGPoint(x: w * 1.09, y: h * 0.15))
            p.addCurve(to: CGPoint(x: w * 0.87, y: h * 0.79), control1: CGPoint(x: w * 1.01, y: h * 0.49), control2: CGPoint(x: w * 1.10, y: h * 0.72))
            p.addCurve(to: CGPoint(x: w * 0.32, y: h * 0.80), control1: CGPoint(x: w * 0.60, y: h * 0.91), control2: CGPoint(x: w * 0.56, y: h * 0.73))
            p.addCurve(to: CGPoint(x: -w * 0.07, y: h * 0.40), control1: CGPoint(x: -w * 0.12, y: h * 0.90), control2: CGPoint(x: -w * 0.13, y: h * 0.59))
            p.addCurve(to: CGPoint(x: w * 0.21, y: h * 0.05), control1: CGPoint(x: -w * 0.03, y: h * 0.22), control2: CGPoint(x: -w * 0.10 + drift, y: h * 0.15))
            p.closeSubpath()
        }
    }

    private static func open(_ points: [CGPoint]) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first); for point in points.dropFirst() { p.addLine(to: point) }
        }
    }

    private static func closed(_ points: [CGPoint]) -> Path {
        Path { p in
            guard points.count > 3 else { return }
            p.move(to: points[0])
            for i in points.indices {
                let a = points[(i + points.count - 1) % points.count], b = points[i]
                let c = points[(i + 1) % points.count], d = points[(i + 2) % points.count]
                p.addCurve(to: c, control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                           control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
            }
            p.closeSubpath()
        }
    }
}
#endif
