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
    @State private var grabbingRobot = false
    @State private var robotStart = CGSize.zero
    @State private var robotHeld = CGSize.zero
    @State private var robotReturn = EnergySiteSpring()
    @State private var releasedAt = Date.distantPast.timeIntervalSinceReferenceDate
    @State private var materialWeights = Array(repeating: 0.0, count: 5)
    private let materialSolver = DistributionMaterialSolver()

    var body: some View {
        GeometryReader { proxy in
            let layout = EnergySiteLayout(size: proxy.size, flow: model.flow)
            let moving = visible && showsLabels && !model.frozen && !reduceMotion && scenePhase == .active
            ZStack {
                TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 20 : 1.0 / 60, paused: !moving)) { clock in
                    let t = moving ? clock.date.timeIntervalSinceReferenceDate : heldTime
                    let offset = robotOffset(at: t)
                    let robot = CGPoint(x: layout.junction.x + offset.width, y: layout.junction.y + offset.height)
                    ZStack {
                        DistributionSiteInk(flow: model.flow, time: t, moving: moving,
                                            finger: finger, origin: origin, grip: grip, robot: robot, weights: materialWeights)
                            .animation(moving ? DistributionStyle.motion : nil, value: [model.flow.solar, model.flow.grid, model.flow.battery, model.flow.car, model.flow.home])
                            .allowsHitTesting(false).accessibilityHidden(true)
                        robotButton(at: robot, offset: offset, time: t)
                    }
                }
                if showsLabels {
                    ForEach(EnergySiteLayout.Part.allCases, id: \.rawValue) { part in
                        siteLabel(part, layout: layout)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dra i roboten eller energin").font(.system(size: 11, weight: .medium))
                    Text("Tryck på en siffra för mer").font(.system(size: 10))
                }.foregroundStyle(DistributionStyle.muted)
                    .position(x: proxy.size.width * 0.25, y: proxy.size.height * 0.785)
                    .allowsHitTesting(false).accessibilityHidden(true).opacity(showsLabels ? 1 : 0)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !grabbing {
                        let offset = robotOffset(at: Date.now.timeIntervalSinceReferenceDate)
                        let center = CGPoint(x: layout.junction.x + offset.width, y: layout.junction.y + offset.height)
                        grabbingRobot = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y) < 58
                        robotStart = offset
                        robotHeld = offset
                        grabbing = true; grip = 1; grabs += 1; model.stop()
                        origin = value.startLocation
                    }
                    finger = value.location
                    if grabbingRobot {
                        robotHeld = CGSize(width: max(48 - layout.junction.x, min(proxy.size.width - 48 - layout.junction.x, robotStart.width + value.translation.width)),
                                           height: max(48 - layout.junction.y, min(proxy.size.height * 0.82 - layout.junction.y, robotStart.height + value.translation.height)))
                    }
                }
                .onEnded { value in
                    if grabbingRobot {
                        robotReturn = reduceMotion ? EnergySiteSpring() : EnergySiteSpring(displacement: robotHeld, velocity: value.velocity)
                        releasedAt = Date.now.timeIntervalSinceReferenceDate
                    }
                    grabbingRobot = false
                    let distance = max(35, hypot(value.translation.width, value.translation.height))
                    let speed = min(4, hypot(value.velocity.width, value.velocity.height) / distance)
                    withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 38, damping: 7.2, initialVelocity: -speed)) {
                        grip = 0; grabbing = false
                    }
                }, including: model.frozen ? .none : .all)
            .sensoryFeedback(.impact(weight: .light), trigger: grabs)
            .accessibilityElement(children: .contain)
        }
        .task(id: [model.flow.solar, model.flow.home, model.flow.car, model.flow.battery, model.flow.grid]) {
            let powers = [model.flow.solar, model.flow.home, model.flow.car, model.flow.battery, model.flow.grid]
            let weights = await materialSolver.solve(powers)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : DistributionStyle.motion) { materialWeights = weights }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; resetGrip() }
        .onChange(of: model.frozen) { _, frozen in
            if frozen { heldTime = Date.now.timeIntervalSinceReferenceDate; resetGrip() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { heldTime = Date.now.timeIntervalSinceReferenceDate } }
    }

    private func robotOffset(at time: Double) -> CGSize {
        if grabbingRobot { return robotHeld }
        return reduceMotion || !showsLabels ? .zero : robotReturn.offset(after: time - releasedAt)
    }

    private func resetGrip() {
        grip = 0; grabbing = false; grabbingRobot = false; robotReturn = EnergySiteSpring()
    }

    private func robotButton(at point: CGPoint, offset: CGSize, time: Double) -> some View {
        Button {
            guard !model.frozen else { return }
            model.stop(); grabs += 1
            robotReturn = EnergySiteSpring(displacement: robotOffset(at: time), velocity: CGSize(width: 0, height: -420))
            releasedAt = Date.now.timeIntervalSinceReferenceDate
        } label: {
            DistributionRobotMark(screen: .now, happy: model.happy || grabbingRobot || time - releasedAt < 0.65,
                                  gaze: max(-2, min(2, offset.width / 70)), rotation: max(-16, min(16, offset.width / 12)),
                                  frozen: model.frozen || !showsLabels)
                .frame(width: 94)
        }
        .buttonStyle(.plain).contentShape(Circle())
        .scaleEffect(grabbingRobot ? 1.09 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: grabbingRobot)
        .position(point)
        .disabled(model.frozen || !showsLabels)
        .accessibilityLabel("Energiroboten")
        .accessibilityHint("Dra för att sträcka energin. Tryck för en mjuk knuff.")
        .accessibilityIdentifier("distribution.robot")
        .accessibilityHidden(!showsLabels)
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
            .multilineTextAlignment(.center).foregroundStyle(part == .solar && info.power < 0.025 ? DistributionStyle.ink : info.ink)
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
private actor DistributionMaterialSolver {
    func solve(_ powers: [Double]) -> [Double] { EnergySiteMix(powers: powers).biases }
}

/// Adjoining color regions fill the viewport. Power sets their relative size;
/// light paths, the robot and touch deformation move the same material.
private nonisolated struct DistributionSiteInk: View, Animatable {
    var flow: EnergyFlowBalance
    let time: Double
    let moving: Bool
    var finger, origin: CGPoint
    var grip: Double
    let robot: CGPoint
    var weights: [Double]
    typealias Pair = AnimatablePair<Double, Double>
    typealias Powers = AnimatablePair<AnimatablePair<Pair, Pair>, Double>
    typealias Contact = AnimatablePair<Pair, Double>
    var animatableData: AnimatablePair<AnimatablePair<Powers, Contact>, Powers> {
        get {
            let powers = Powers(.init(.init(flow.solar, flow.grid), .init(flow.battery, flow.car)), flow.home)
            let colorWeights = Powers(.init(.init(weights[0], weights[1]), .init(weights[2], weights[3])), weights[4])
            return .init(.init(powers, .init(.init(finger.x, finger.y), grip)), colorWeights)
        }
        set {
            let p = newValue.first.first, color = newValue.second
            flow = .init(solar: p.first.first.first, grid: p.first.first.second, battery: p.first.second.first,
                         car: p.first.second.second, home: p.second)
            finger = CGPoint(x: newValue.first.second.first.first, y: newValue.first.second.first.second)
            grip = newValue.first.second.second
            weights = [color.first.first.first, color.first.first.second, color.first.second.first, color.first.second.second, color.second]
        }
    }

    @MainActor var body: some View {
        GeometryReader { proxy in
            let layout = EnergySiteLayout(size: proxy.size, flow: flow)
            ZStack {
                Rectangle().fill(DistributionStyle.eye).colorEffect(material(size: proxy.size)).ignoresSafeArea(edges: .bottom)
                Canvas { context, _ in
                    for part in EnergySiteLayout.Part.allCases where abs(layout.signedPower(part)) > 0.025 {
                        let points = layout.stream(part, finger: finger, origin: origin, grip: max(0, grip), time: moving ? time : 0, anchor: robot)
                        let path = Self.path(points)
                        let info = DistributionSiteInfo(part: part, flow: flow, level: 62)
                        var ink = context
                        ink.addFilter(.blur(radius: part == .solar ? 17 : 12))
                        ink.stroke(path, with: .color(info.color.opacity(part == .solar ? 0.22 : 0.12)),
                                   style: StrokeStyle(lineWidth: 24 + sqrt(info.power) * 15, lineCap: .round, lineJoin: .round))
                        if moving {
                            DistributionFluidInk.paint(path, power: info.power, time: time, color: DistributionStyle.eye, context: context, scale: 1.4)
                        }
                    }
                    DistributionFluidInk.contact(finger: finger, strength: grip, context: context)
                }
            }
        }
    }

    @MainActor private func material(size: CGSize) -> Shader {
        var shader = ShaderLibrary.ftwSite(
            .float2(size), .float4(flow.solar, flow.car, flow.battery, 0.0),
            .float4(finger.x, finger.y, origin.x, origin.y),
            .float4(grip, time.truncatingRemainder(dividingBy: 4096), flow.grid, flow.home), .float2(robot),
            .float4(weights[0], weights[1], weights[2], weights[3]), .float(weights[4]),
            .color(DistributionStyle.home), .color(DistributionStyle.purple), .color(DistributionStyle.cyan),
            .color(DistributionStyle.gold), .color(DistributionStyle.green), .color(DistributionStyle.eye))
        shader.dithersColor = true
        return shader
    }

    private static func path(_ points: [CGPoint]) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for point in points.dropFirst() { p.addLine(to: point) }
        }
    }
}
#endif
