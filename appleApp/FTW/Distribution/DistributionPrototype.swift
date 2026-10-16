#if DEBUG && targetEnvironment(simulator)
import FTWShared
import SwiftUI
import Charts

enum DistributionStyle {
    static let ground = Color("distribution.ground")
    static let ink = Color("distribution.ink")
    static let muted = Color("distribution.muted")
    static let raised = Color("distribution.raised")
    static let line = Color("distribution.line")
    static let purple = Color("distribution.purple")
    static let purpleDeep = Color("distribution.purpleDeep")
    static let purpleInk = Color("distribution.purpleInk")
    static let home = Color("distribution.home")
    static let homeInk = Color("distribution.homeInk")
    static let green = Color("distribution.green")
    static let greenInk = Color("distribution.greenInk")
    static let cyan = Color("distribution.cyan")
    static let cyanInk = Color("distribution.cyanInk")
    static let gold = Color("distribution.gold")
    static let goldInk = Color("distribution.goldInk")
    static let eye = Color("distribution.eye")
    static let motion = Animation.spring(response: 1.2, dampingFraction: 0.94)
    static let colors = [purple, home, cyan, green]
    static let inks = [purpleInk, homeInk, cyanInk, greenInk]
    static let routes: [DistributionScreen] = [.car, .home, .battery, .grid]
    static let names = ["Bilen", "Hemmet", "Batteriet", "Till nätet"]
    static let symbols = ["car.side", "house", "battery.75percent", "powerplug"]
    static func number(_ value: Double) -> String { String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") }
}

/// A native, simulator-only counterpart to the reviewed design. It has its
/// own state and cannot reach a real box or use the phone's saved home.
struct DistributionPrototype: View {
    @State private var model = DistributionModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.paired {
                DistributionNavigation(root: .pair)
            } else {
                TabView(selection: $model.tab) {
                    DistributionNavigation(root: .now)
                        .tabItem { Label("Nu", systemImage: "circle.hexagongrid") }.tag(DistributionScreen.now)
                    DistributionNavigation(root: .plan)
                        .tabItem { Label("Plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(DistributionScreen.plan)
                    DistributionNavigation(root: .history)
                        .tabItem { Label("Historik", systemImage: "chart.xyaxis.line") }.tag(DistributionScreen.history)
                    DistributionNavigation(root: .box)
                        .tabItem { Label("Hemmet", systemImage: "house") }.tag(DistributionScreen.box)
                }
            }
        }
        .environment(model)
        .tint(DistributionStyle.ink)
        .background(DistributionStyle.ground)
        .sheet(item: $model.sheet) { sheet in DistributionEditor(sheet: sheet).environment(model) }
        .sensoryFeedback(.success, trigger: model.feedback)
        .onChange(of: model.tab) { _, _ in model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .task(id: model.playbackGeneration) {
            guard model.playing, !reduceMotion, scenePhase == .active else { return }
            do {
                for value in [DistributionScenario.surplus, .mixed, .importing, .battery, .night, .sun] {
                    try await Task.sleep(for: .seconds(4.5))
                    guard model.playing, scenePhase == .active else { return }
                    withAnimation(DistributionStyle.motion) {
                        model.scenario = value
                        model.lastSource = value
                        model.powers = value.powers!
                    }
                }
                try await Task.sleep(for: .seconds(2))
                model.playing = false
            } catch { model.playing = false }
        }
        .onAppear { LaunchClock.mark("first frame"); LaunchClock.mark("first content") }
    }
}

struct DistributionNavigation: View {
    let root: DistributionScreen
    @State private var path: [DistributionScreen] = []
    @Environment(DistributionModel.self) private var model
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            page(root)
                .navigationDestination(for: DistributionScreen.self) { route in
                    page(route).navigationTransition(.zoom(sourceID: route, in: zoom))
                }
        }
        .onAppear {
            if root == .now, let initial = model.startScreen { path = [initial]; model.startScreen = nil }
        }
    }

    private func page(_ route: DistributionScreen) -> some View {
        DistributionPage(screen: route, namespace: zoom)
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DistributionStyle.ground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.sheet = .demo } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Demolägen").accessibilityIdentifier("distribution.demo")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    Text("KONCEPT · EXEMPELDATA").font(.caption2).tracking(1.8).foregroundStyle(DistributionStyle.muted)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    if let freshness = model.freshness {
                        Text(freshness).font(.caption).padding(10).frame(maxWidth: .infinity)
                            .foregroundStyle(DistributionStyle.goldInk).background(DistributionStyle.gold)
                    }
                }
                .padding(.top, 4).padding(.bottom, 8).frame(maxWidth: .infinity).background(DistributionStyle.ground)
            }
    }
}

struct DistributionPage: View {
    let screen: DistributionScreen
    let namespace: Namespace.ID
    @Environment(DistributionModel.self) private var model

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 28)
        }
        .background(DistributionStyle.ground)
        .foregroundStyle(DistributionStyle.ink)
        .accessibilityIdentifier("distribution.screen.\(screen.rawValue)")
        .onAppear { if screen != .now { model.stop() } }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .now: DistributionNow(namespace: namespace)
        case .car: DistributionCar()
        case .solar, .home, .battery, .grid: DistributionNode(node: screen)
        case .plan: DistributionPlan()
        case .prices: DistributionPrices()
        case .history: DistributionHistory()
        case .box: DistributionHome()
        default: DistributionSettings(screen: screen)
        }
    }
}

struct DistributionRobot: View {
    var happy = false
    var frozen = false
    var gaze = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || frozen || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let moving = !reduceMotion && !frozen && scenePhase == .active
            let cycle = t.truncatingRemainder(dividingBy: 4.4)
            let blink = moving && cycle < 0.23 ? max(0.05, 1 - sin(cycle / 0.23 * .pi)) : 1
            GeometryReader { geometry in
                let w = geometry.size.width
                ZStack {
                    Image("DistributionRobot").resizable().scaledToFit()
                    ForEach([0.393, 0.607], id: \.self) { x in
                        Group {
                            if happy {
                                Capsule().trim(from: 0.05, to: 0.45).stroke(DistributionStyle.eye, style: StrokeStyle(lineWidth: w * 0.025, lineCap: .round))
                                    .rotationEffect(.degrees(180)).frame(width: w * 0.09, height: w * 0.06)
                            } else {
                                Ellipse().fill(DistributionStyle.eye)
                                    .frame(width: w * 0.06, height: w * 0.104)
                                    .scaleEffect(y: blink)
                                    .shadow(color: DistributionStyle.eye.opacity(0.4), radius: 3)
                            }
                        }
                        .position(x: w * x + gaze * 2, y: w * 0.512)
                    }
                }
                .offset(y: moving ? sin(t * 1.4) * 1.8 : 0)
                .rotationEffect(.degrees(moving ? gaze * 2 + sin(t * 0.7) : 0))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: DistributionStyle.ink.opacity(0.16), radius: 9, y: 9)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct DistributionNow: View {
    let namespace: Namespace.ID
    @Environment(DistributionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            DistributionTouchableField(namespace: namespace)
            VStack(spacing: 3) {
                Text("Dra och putta · tryck för att öppna")
                Text("Yta = andel · rörelse = energins riktning")
            }.font(.caption2).foregroundStyle(DistributionStyle.muted).padding(.vertical, 10)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            if typeSize.isAccessibilitySize {
                VStack {
                    ForEach(0..<4) { i in
                        if model.flow.destinations[i] > 0.025 {
                            NavigationLink(value: DistributionStyle.routes[i]) {
                                LabeledContent(DistributionStyle.names[i], value: "\(DistributionStyle.number(model.flow.destinations[i])) kW")
                            }.padding(.vertical, 10)
                                .accessibilityIdentifier("distribution.accessible.\(DistributionStyle.routes[i].rawValue)")
                        }
                    }
                }.padding(.horizontal, 24)
            }
            HStack(alignment: .top, spacing: 24) {
                NavigationLink(value: DistributionScreen.car) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Bilen · \(model.level) % nu").font(.caption).foregroundStyle(DistributionStyle.muted)
                        Text(model.goal > 0 ? "\(model.goal) % till \(model.clock)" : "Inget laddmål").font(.headline)
                    }
                }
                Spacer(minLength: 0)
                NavigationLink(value: DistributionScreen.prices) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Elpris just nu").font(.caption).foregroundStyle(DistributionStyle.muted)
                        Text("44 öre/kWh ↗").font(.headline)
                    }
                }
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 12)
            NavigationLink(value: DistributionScreen.battery) {
                HStack { Text("Batteriet · 68 %"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 14)
        }
    }
}

struct DistributionTouchableField: View {
    let namespace: Namespace.ID
    private let fieldHeight: CGFloat = 370
    @Environment(DistributionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var force = CGSize.zero
    @State private var touch = CGPoint(x: 0.5, y: 0.5)
    @State private var grabbing = false
    @State private var visible = false
    @State private var heldPhase = Date.now.timeIntervalSinceReferenceDate * 0.22
    @State private var grabs = 0
    @State private var releasedAt = Date.distantPast
    @State private var releaseStrength = 0.0
    @State private var finger = CGPoint.zero
    @State private var origin = CGPoint.zero
    @State private var grip = 0.0
    @State private var sourceHeight: CGFloat = 142
    @State private var surfaceWidth: CGFloat = 390

    var body: some View {
        VStack(spacing: 0) {
            DistributionInlets(flow: model.flow, finger: finger, origin: origin, grip: grip, frozen: model.frozen)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sourceHeight = $0 }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || model.frozen || !visible || scenePhase != .active)) { clock in
                let phase = reduceMotion || model.frozen ? heldPhase : clock.date.timeIntervalSinceReferenceDate * 0.22
                let elapsed = max(0, clock.date.timeIntervalSince(releasedAt))
                let ripple = reduceMotion || model.frozen || elapsed > 3 ? 0 : sin(elapsed * 9) * exp(-elapsed * 2.4) * releaseStrength
                DistributionField(powers: model.flow.destinations, flow: model.flow, namespace: namespace, happy: model.happy, frozen: model.frozen,
                                  phase: phase, time: reduceMotion || model.frozen ? 0 : clock.date.timeIntervalSinceReferenceDate,
                                  drag: force, touch: touch, grabbing: grabbing, ripple: ripple,
                                  finger: CGPoint(x: finger.x, y: finger.y - sourceHeight), grip: grip)
                    .animation(reduceMotion || model.frozen ? nil : DistributionStyle.motion, value: model.flow.destinations)
            }.frame(height: fieldHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { surfaceWidth = $0 }
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !grabbing {
                        grabbing = true; grip = 1; grabs += 1; releaseStrength = 0; model.stop()
                        heldPhase = Date.now.timeIntervalSinceReferenceDate * 0.22
                        origin = value.startLocation
                    }
                    finger = value.location
                    touch = CGPoint(x: origin.x / max(1, surfaceWidth), y: (origin.y - sourceHeight) / fieldHeight)
                    force = CGSize(width: tanh(value.translation.width / 95), height: tanh(value.translation.height / 105))
                }
                .onEnded { value in
                    let distance = max(35, hypot(value.translation.width, value.translation.height))
                    let outward = (value.velocity.width * force.width + value.velocity.height * force.height) / distance
                    let velocity = max(-5, min(5, -outward))
                    releasedAt = .now
                    releaseStrength = min(1, hypot(force.width, force.height))
                    withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 40, damping: 6.5, initialVelocity: velocity)) {
                        force = .zero; grip = 0; grabbing = false
                    }
                }, including: model.frozen ? .none : .all)
            .sensoryFeedback(.impact(weight: .light), trigger: grabs)
            .accessibilityElement(children: .contain)
        .onAppear { visible = true }
        .onDisappear { visible = false; force = .zero; grip = 0; grabbing = false }
        .onChange(of: model.frozen) { _, frozen in if frozen { heldPhase = Date.now.timeIntervalSinceReferenceDate * 0.22; force = .zero; grip = 0; grabbing = false } }
    }
}

nonisolated struct DistributionField: View, Animatable {
    private var a, b, c, d: Double
    private var phase: Double
    private var drag: CGSize
    private var touch: CGPoint
    private var finger: CGPoint
    private var grip: Double
    let flow: EnergyFlowBalance
    let time, ripple: Double
    let grabbing: Bool
    let namespace: Namespace.ID
    var happy: Bool
    var frozen: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(powers: [Double], flow: EnergyFlowBalance, namespace: Namespace.ID, happy: Bool, frozen: Bool, phase: Double = 0, time: Double = 0, drag: CGSize = .zero, touch: CGPoint = CGPoint(x: 0.5, y: 0.5), grabbing: Bool = false, ripple: Double = 0, finger: CGPoint = .zero, grip: Double = 0) {
        a = powers[0]; b = powers[1]; c = powers[2]; d = powers[3]
        self.namespace = namespace; self.happy = happy; self.frozen = frozen
        self.phase = phase; self.drag = drag; self.touch = touch; self.grabbing = grabbing
        self.flow = flow; self.time = time; self.ripple = ripple
        self.finger = finger; self.grip = grip
    }
    typealias Four = AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    typealias Eight = AnimatablePair<Four, Four>
    typealias Contact = AnimatablePair<AnimatablePair<Double, Double>, Double>
    var animatableData: AnimatablePair<Eight, Contact> {
        get { .init(.init(.init(.init(a, b), .init(c, d)), .init(.init(Double(drag.width), Double(drag.height)), .init(Double(touch.x), Double(touch.y)))), .init(.init(Double(finger.x), Double(finger.y)), grip)) }
        set {
            let field = newValue.first
            a = field.first.first.first; b = field.first.first.second
            c = field.first.second.first; d = field.first.second.second
            drag = CGSize(width: field.second.first.first, height: field.second.first.second)
            touch = CGPoint(x: field.second.second.first, y: field.second.second.second)
            finger = CGPoint(x: newValue.second.first.first, y: newValue.second.first.second)
            grip = newValue.second.second
        }
    }
    @MainActor var body: some View {
        GeometryReader { proxy in
            let values = [a, b, c, d].map { max(0, $0) }
            let layout = EnergyPartition(powers: values, size: proxy.size, phase: phase, drag: drag, touch: touch, ripple: ripple)
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                ZStack {
                    ZStack {
                        ForEach([3, 2, 1, 0], id: \.self) { i in
                            fieldPath(layout.polygons[i])
                                .fill(LinearGradient(colors: [DistributionStyle.colors[i], i == 0 ? DistributionStyle.purpleDeep : DistributionStyle.colors[i].opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }.blur(radius: 1.8)
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.035), .init(color: .white, location: 0.96), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        }
                    DistributionFluidInk(layout: layout, flow: flow, time: time, drag: drag, touch: touch, finger: finger, grip: grip)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                ForEach(0..<4) { i in
                    if values[i] > 0.025 {
                        let center = layout.centers[i]
                        let tiny = layout.areas[i] < 12_000
                        let halfHeight: CGFloat = tiny ? 26 : 55
                        NavigationLink(value: DistributionStyle.routes[i]) {
                            VStack(spacing: 3) {
                                if !tiny {
                                    HStack(spacing: 5) {
                                        Image(systemName: DistributionStyle.symbols[i]).font(.system(size: 20))
                                        Image(systemName: i == 0 ? "arrow.left" : i == 3 ? "arrow.up" : "arrow.right").font(.system(size: 11, weight: .medium))
                                    }
                                    Text(["Till bilen", "Till hemmet", "Till batteriet", "Till nätet"][i]).font(.system(size: 13))
                                } else {
                                    HStack(spacing: 3) {
                                        Text(["Till bilen", "Till hemmet", "Till batteriet", "Till nätet"][i])
                                        Image(systemName: i == 0 ? "arrow.left" : i == 3 ? "arrow.up" : "arrow.right")
                                    }.font(.system(size: 10, weight: .medium))
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(DistributionStyle.number(values[i])).font(.system(size: tiny ? 20 : 27, weight: .medium))
                                    Text("kW").font(.system(size: 12))
                                }.monospacedDigit()
                                if !tiny { Text("\(layout.percentages[i]) %").font(.system(size: 11)) }
                            }
                            .foregroundStyle(DistributionStyle.inks[i])
                            .frame(width: min(112, max(62, w * (i == 0 ? layout.shares[0] : 1 - layout.shares[0]) - 22)), height: tiny ? 48 : 100)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .matchedTransitionSource(id: DistributionStyle.routes[i], in: namespace)
                        .position(x: max(40, min(w - 40, center.x)), y: max(halfHeight, min(h - halfHeight, center.y)))
                        .accessibilityLabel("\(DistributionStyle.names[i]), \(DistributionStyle.number(values[i])) kilowatt")
                        .accessibilityIdentifier("distribution.field.\(DistributionStyle.routes[i].rawValue)")
                        .accessibilityHidden(typeSize.isAccessibilitySize)
                    }
                }
                DistributionRobot(happy: happy, frozen: frozen, gaze: Double(drag.width) * 2)
                    .frame(width: 102)
                    .rotationEffect(.degrees(Double(drag.width) * 8))
                    .position(x: max(62, min(w - 62, layout.junction.x - 16)), y: max(64, min(h - 62, layout.junction.y - 35)))
            }
            .clipped()
        }
    }
    private func fieldPath(_ points: [CGPoint]) -> Path {
        Path {
            p in guard let first = points.first else { return }
            p.move(to: first)
            for point in points.dropFirst() { p.addLine(to: point) }
            p.closeSubpath()
        }
    }
}

struct DistributionHero: View {
    let title, value, unit, detail: String
    let color, ink: Color
    var flowPower = 0.0
    @Environment(DistributionModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var figure = 66.0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased()).font(.caption).tracking(2)
            HStack(alignment: .center, spacing: 12) {
                Text("\(Text(value).font(.system(size: figure, weight: .regular)))\(Text(" \(unit)").font(.title))")
                    .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DistributionRobot(happy: model.happy, frozen: model.frozen, gaze: model.gaze).frame(width: 108)
            }
            Text(detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
        .padding(26).padding(.bottom, 25)
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DistributionHeroMaterial(color: color, power: flowPower, frozen: model.frozen))
    }
}

private struct DistributionHeroMaterial: View {
    let color: Color
    let power: Double
    let frozen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var heldPhase = Date.now.timeIntervalSinceReferenceDate * 0.6

    var body: some View {
        let moving = visible && power > 0.025 && !frozen && !reduceMotion && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { clock in
            let t = clock.date.timeIntervalSinceReferenceDate
            let shape = HeroField(phase: moving ? t * 0.6 : heldPhase)
            ZStack {
                shape.fill(color.gradient).blur(radius: 1.5)
                if moving {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: size.width * 0.55, y: -40))
                        path.addCurve(to: CGPoint(x: size.width * 0.18, y: size.height + 30),
                                      control1: CGPoint(x: size.width * 0.28, y: size.height * 0.25),
                                      control2: CGPoint(x: size.width * 0.45, y: size.height * 0.7))
                        DistributionFluidInk.paint(path, power: power, time: t, color: DistributionStyle.eye, context: context, scale: 1.6)
                    }.mask(shape).allowsHitTesting(false)
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: moving) { _, value in if !value { heldPhase = Date.now.timeIntervalSinceReferenceDate * 0.6 } }
        .accessibilityHidden(true)
    }
}

private struct HeroField: Shape {
    var phase = 0.0
    func path(in r: CGRect) -> Path {
        Path { p in
            let wave = sin(phase) * 8
            p.move(to: .zero); p.addLine(to: CGPoint(x: r.maxX, y: 0)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 20))
            p.addCurve(to: CGPoint(x: 0, y: r.maxY), control1: CGPoint(x: r.width * 0.75, y: r.maxY - 55 + wave), control2: CGPoint(x: r.width * 0.3, y: r.maxY - 30 - wave))
            p.closeSubpath()
        }
    }
}

struct DistributionActionStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(prominent ? DistributionStyle.ground : DistributionStyle.ink)
            .background(prominent ? DistributionStyle.ink : DistributionStyle.raised, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct DistributionCar: View {
    @Environment(DistributionModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            DistributionHero(title: "Bilen", value: "\(model.level)", unit: "%", detail: model.frozen ? "Senast kända läget · \(DistributionStyle.number(model.powers[0])) kW till bilen." : model.hold == "paused" ? "Laddningen är pausad." : model.hold == "now" ? "Laddar nu. Du väljer när planen tar över." : "Laddar med \(DistributionStyle.number(model.powers[0])) kW.", color: DistributionStyle.purple, ink: DistributionStyle.purpleInk, flowPower: model.powers[0])
            VStack(alignment: .leading, spacing: 20) {
                Button { model.sheet = .goal } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.goal > 0 ? "\(model.goal) % till \(model.clock)" : "Sätt ett laddmål").font(.title2.weight(.medium))
                            Text("\(model.days) · boxen planerar mot målet").font(.caption).foregroundStyle(DistributionStyle.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }
                }.buttonStyle(.plain).disabled(!model.canControl || model.sending).accessibilityIdentifier("distribution.goal")
                GeometryReader { p in
                    Capsule().fill(DistributionStyle.raised)
                    Capsule().fill(DistributionStyle.purple).frame(width: p.size.width * Double(model.level) / 100)
                }.frame(height: 6).accessibilityLabel("Bilens nivå \(model.level) procent")
                Button("Justera bilens nivå") { model.sheet = .level }.disabled(!model.canControl || model.sending)
                    .accessibilityIdentifier("distribution.level")
                Divider()
                HStack(spacing: 8) {
                    if model.hold != "plan" { command("Till planen", symbol: "calendar", hold: "plan") }
                    if model.hold != "now" { command("Ladda nu", symbol: "bolt", hold: "now") }
                    if model.hold != "paused" { command("Pausa", symbol: "pause", hold: "paused", prominent: false) }
                }
                Text(model.receipt.isEmpty ? " " : model.receipt).font(.caption).foregroundStyle(DistributionStyle.muted)
                    .frame(minHeight: 20, alignment: .leading).accessibilityIdentifier("distribution.receipt")
                Text(model.canControl ? "Ladda nu fortsätter tills du går tillbaka till planen eller kopplar ur." : model.scenario == .viewer ? "Du kan se bilen. Ägaren ändrar mål och laddning." : "Du kan styra när kontakten och färska mätvärden är tillbaka.")
                    .font(.caption).foregroundStyle(DistributionStyle.muted)
            }.padding(24)
        }
    }
    private func command(_ title: String, symbol: String, hold: String, prominent: Bool = true) -> some View {
        Button { Task { await model.submit(.hold(hold)) } } label: { Label(title, systemImage: symbol) }
            .buttonStyle(DistributionActionStyle(prominent: prominent))
            .disabled(!model.canControl || model.sending)
            .accessibilityIdentifier("distribution.hold.\(hold)")
    }
}

struct DistributionNode: View {
    let node: DistributionScreen
    @Environment(DistributionModel.self) private var model
    private var info: (String, String, String, Color, Color) {
        switch node {
        case .solar: (DistributionStyle.number(model.flow.solar), "kW", model.flow.solar > 0 ? "Solen tillför energi till hemmet." : "Solen tillför ingen energi just nu.", DistributionStyle.gold, DistributionStyle.goldInk)
        case .home: (DistributionStyle.number(model.powers[1]), "kW", "Hemmets förbrukning just nu.", DistributionStyle.home, DistributionStyle.homeInk)
        case .battery: ("68", "%", model.flow.battery > 0 ? "Laddas med \(DistributionStyle.number(model.flow.battery)) kW." : model.flow.battery < 0 ? "Tillför \(DistributionStyle.number(-model.flow.battery)) kW till hemmet." : "Vilar just nu. Hjälper hemmet i kväll.", DistributionStyle.cyan, DistributionStyle.cyanInk)
        default: (DistributionStyle.number(abs(model.flow.grid)), "kW", model.flow.grid > 0.025 ? "Köpt el fyller på när solen inte räcker." : model.flow.grid < -0.025 ? "Överskottet går till elnätet." : "Inget flöde till eller från nätet just nu.", DistributionStyle.green, DistributionStyle.greenInk)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            DistributionHero(title: node == .grid ? (model.flow.grid > 0.025 ? "Från nätet" : "Till nätet") : node.title, value: info.0, unit: info.1, detail: info.2, color: info.3, ink: info.4,
                             flowPower: node == .solar ? model.flow.solar : node == .home ? model.flow.home : node == .battery ? abs(model.flow.battery) : abs(model.flow.grid))
            VStack(alignment: .leading, spacing: 22) {
                switch node {
                case .solar:
                    LabeledContent("Producerat i dag", value: "18,6 kWh")
                    Chart(Array([0.0, 0.1, 0.8, 2.4, 4.6, 4.2, 3.2, 1.6, 0.4, 0].enumerated()), id: \.offset) { point in
                        AreaMark(x: .value("Tid", point.offset + 6), y: .value("kW", point.element))
                            .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.gold.gradient)
                    }.frame(height: 150).chartYScale(domain: 0...5).chartXAxisLabel("Tid").chartYAxisLabel("kW")
                case .home:
                    Text("Säkringen har utrymme").font(.title3.weight(.medium))
                    Text("Ström per fas · huvudsäkring 16 A").font(.caption).foregroundStyle(DistributionStyle.muted)
                    ForEach(Array([8.4, 6.2, 7.1].enumerated()), id: \.offset) { item in
                        HStack { Text("L\(item.offset + 1)").font(.caption); ProgressView(value: item.element, total: 16).tint(DistributionStyle.home); Text("\(DistributionStyle.number(item.element)) A").font(.caption).monospacedDigit() }
                    }
                    LabeledContent("Använt hemma i dag", value: "15,2 kWh")
                case .battery:
                    LabeledContent("Lagrad energi", value: "9,5 kWh")
                    LabeledContent("Exempelhemmets kapacitet", value: "14 kWh")
                    Text("Boxen planerar batteriet med elpriset, solen och hemmets behov.").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                    NavigationLink("Se batteriets plan", value: DistributionScreen.plan)
                default:
                    LabeledContent("Sålt i dag", value: "5,8 kWh")
                    LabeledContent("Köpt i dag", value: "2,4 kWh")
                    Text("Effekt i kW visar flödet just nu. Energi i kWh visar mängden över tid.").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                    NavigationLink("Se elpriset", value: DistributionScreen.prices)
                }
                NavigationLink("Se dagens energi", value: DistributionScreen.history)
            }.padding(24)
        }
    }
}
#endif
