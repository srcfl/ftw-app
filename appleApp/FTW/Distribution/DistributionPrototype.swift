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
        .overlayPreferenceValue(DistributionRobotAnchors.self) { anchors in
            GeometryReader { geometry in
                let placement = anchors[model.visibleScreen]
                DistributionCompanion(target: placement.map { geometry[$0.bounds] }, placement: placement)
            }.allowsHitTesting(false)
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
        Group {
            if screen == .now {
                DistributionNow(namespace: namespace)
            } else {
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 28)
                }
            }
        }
        .background(DistributionStyle.ground)
        .foregroundStyle(DistributionStyle.ink)
        .accessibilityIdentifier("distribution.screen.\(screen.rawValue)")
        .onAppear { model.visibleScreen = screen; if screen != .now { model.stop() } }
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
    var receivesTouch = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 20 : 1.0 / 60, paused: reduceMotion || frozen || scenePhase != .active)) { context in
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
        .allowsHitTesting(receivesTouch)
    }
}

struct DistributionHero: View {
    let title, value, unit, detail: String
    let color, ink: Color
    var flowPower = 0.0
    var route = DistributionScreen.car
    var phase = 0.0
    @Environment(DistributionModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var figure = 66.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DistributionHeader(color: color, power: flowPower, phase: phase, bottomSpace: 12) { pull in
                VStack(alignment: .leading, spacing: 18) {
                    Text(title.uppercased()).font(.caption).tracking(2)
                    HStack(alignment: .center, spacing: 12) {
                        Text("\(Text(value).font(.system(size: figure, weight: .regular)))\(Text(" \(unit)").font(.title))")
                            .monospacedDigit().minimumScaleFactor(0.55).lineLimit(1)
                            .contentTransition(.numericText())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DistributionRobotMark(screen: route, happy: model.happy || pull != .zero, gaze: pull.width / 100,
                                              rotation: pull.width / 12, frozen: model.frozen)
                            .frame(width: 108).offset(x: pull.width * 0.48, y: pull.height * 0.48)
                    }
                }.foregroundStyle(ink)
            }
            Text(detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(DistributionStyle.ink).padding(.horizontal, 26).padding(.bottom, 24)
        }
    }
}

struct DistributionActionStyle: ButtonStyle {
    var prominent = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(prominent ? DistributionStyle.ground : DistributionStyle.ink)
            .background {
                Capsule().fill((prominent ? DistributionStyle.ink : DistributionStyle.raised).gradient
                    .shadow(.inner(color: DistributionStyle.eye.opacity(prominent ? 0.15 : 0.5), radius: 3, x: -1, y: -2))
                    .shadow(.inner(color: DistributionStyle.ink.opacity(0.12), radius: 4, x: 1, y: 3)))
                    .shadow(color: DistributionStyle.ink.opacity(configuration.isPressed ? 0.03 : 0.1), radius: configuration.isPressed ? 2 : 7, y: configuration.isPressed ? 1 : 5)
            }
            .scaleEffect(x: configuration.isPressed ? 0.97 : 1, y: configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.63), value: configuration.isPressed)
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
                }.buttonStyle(DistributionPressStyle()).disabled(!model.canControl || model.sending).accessibilityIdentifier("distribution.goal")
                DistributionLevel(value: Double(model.level) / 100, color: DistributionStyle.purple)
                Text("Bilens nivå \(model.level) %").font(.caption).foregroundStyle(DistributionStyle.muted)
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
            }.modifier(DistributionSection(color: DistributionStyle.purple))
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
    @State private var solarHour = 11
    private let solarSamples = [0.0, 0.1, 0.8, 2.4, 4.6, 4.2, 3.2, 1.6, 0.4, 0]
    private var info: (String, String, String, Color, Color) {
        switch node {
        case .solar: (DistributionStyle.number(model.flow.solar), "kW", model.flow.solar > 0 ? "Solen tillför energi till hemmet." : "Solen tillför ingen energi just nu.", DistributionStyle.gold, DistributionStyle.goldInk)
        case .home: (DistributionStyle.number(model.powers[1]), "kW", "Hemmets förbrukning just nu.", DistributionStyle.home, DistributionStyle.homeInk)
        case .battery: ("68", "%", model.flow.battery > 0 ? "Laddas med \(DistributionStyle.number(model.flow.battery)) kW." : model.flow.battery < 0 ? "Tillför \(DistributionStyle.number(-model.flow.battery)) kW till hemmet." : "Vilar just nu. Hjälper hemmet i kväll.", DistributionStyle.cyan, DistributionStyle.cyanInk)
        default: (DistributionStyle.number(abs(model.flow.grid)), "kW", model.flow.grid > 0.025 ? "Köpt el fyller på när solen inte räcker." : model.flow.grid < -0.025 ? "Överskottet går till elnätet." : "Inget flöde till eller från nätet just nu.", DistributionStyle.green, DistributionStyle.greenInk)
        }
    }
    private var phaseAmps: [Double] {
        // Balanced 230 V sample derived from the same net exchange, not load.
        Array(repeating: abs(model.flow.grid) * 1000 / (3 * 230), count: 3)
    }
    var body: some View {
        VStack(spacing: 0) {
            DistributionHero(title: node == .grid ? (model.flow.grid > 0.025 ? "Från nätet" : model.flow.grid < -0.025 ? "Till nätet" : "Nätet i balans") : node.title, value: info.0, unit: info.1, detail: info.2, color: info.3, ink: info.4,
                             flowPower: node == .solar ? model.flow.solar : node == .home ? model.flow.home : node == .battery ? abs(model.flow.battery) : abs(model.flow.grid), route: node)
            VStack(alignment: .leading, spacing: 22) {
                switch node {
                case .solar:
                    LabeledContent("Producerat i dag", value: "18,6 kWh")
                    Chart(Array(solarSamples.enumerated()), id: \.offset) { point in
                        AreaMark(x: .value("Tid", point.offset + 6), y: .value("kW", point.element))
                            .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.gold.gradient)
                        LineMark(x: .value("Tid", point.offset + 6), y: .value("kW", point.element))
                            .interpolationMethod(.monotone).foregroundStyle(DistributionStyle.gold)
                            .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }.frame(height: 150).chartYScale(domain: 0...5).chartXScale(domain: 6...15)
                        .chartXAxisLabel("Tid").chartYAxisLabel("kW")
                        .chartOverlay { chart in
                            GeometryReader { geometry in
                                if let frame = chart.plotFrame, let x = chart.position(forX: solarHour) {
                                    let plot = geometry[frame]
                                    Capsule().fill(DistributionStyle.ink.opacity(0.2)).frame(width: 2, height: plot.height)
                                        .position(x: plot.minX + x, y: plot.midY)
                                }
                            }.allowsHitTesting(false)
                        }
                        .chartXSelection(value: Binding(get: { Optional(solarHour) }, set: { if let hour = $0 { solarHour = max(6, min(15, hour)) } }))
                        .chartGesture { chart in DragGesture(minimumDistance: 0).onChanged { chart.selectXValue(at: $0.location.x) } }
                    Text("\(solarHour).00 · \(DistributionStyle.number(solarSamples[solarHour - 6])) kW · dra i grafen")
                        .font(.caption).foregroundStyle(DistributionStyle.muted)
                case .home:
                    Text("Hemmets last").font(.title3.weight(.medium))
                    Text("Det hemmet använder, utöver bilen och batteriets laddning.")
                        .font(.subheadline).foregroundStyle(DistributionStyle.muted)
                    LabeledContent("Använt hemma i dag", value: "15,2 kWh")
                case .battery:
                    DistributionLevel(value: 0.68, color: DistributionStyle.cyan)
                    LabeledContent("Lagrad energi", value: "9,5 kWh")
                    LabeledContent("Exempelhemmets kapacitet", value: "14 kWh")
                    Text("Boxen planerar batteriet med elpriset, solen och hemmets behov.").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                    NavigationLink("Se batteriets plan", value: DistributionScreen.plan)
                default:
                    Text("Nätanslutningens faser").font(.title3.weight(.medium))
                    Text("L1 · L2 · L3 · huvudsäkring 16 A").font(.caption).foregroundStyle(DistributionStyle.muted)
                    ForEach(Array(phaseAmps.enumerated()), id: \.offset) { item in
                        HStack {
                            Text("L\(item.offset + 1)").font(.caption).frame(width: 24)
                            ProgressView(value: item.element, total: 16).tint(DistributionStyle.greenInk)
                            Text("\(DistributionStyle.number(item.element)) A").font(.caption).monospacedDigit()
                        }
                    }
                    Text(model.flow.grid > 0.025 ? "Ström in till fastigheten." : model.flow.grid < -0.025 ? "Ström ut från fastigheten." : "Inget utbyte i exemplet.").font(.caption).foregroundStyle(DistributionStyle.muted)
                    LabeledContent("Sålt i dag", value: "5,8 kWh")
                    LabeledContent("Köpt i dag", value: "2,4 kWh")
                    Text("Effekt i kW visar flödet just nu. Energi i kWh visar mängden över tid.").font(.subheadline).foregroundStyle(DistributionStyle.muted)
                    NavigationLink("Se elpriset", value: DistributionScreen.prices)
                }
                NavigationLink("Se dagens energi", value: DistributionScreen.history)
            }.modifier(DistributionSection(color: info.3))
        }
    }
}
#endif
