#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// The same soft shared seam as the site, used at different scales.
/// Only present power advances by itself; plans and history move under a finger.
struct DistributionMaterial: View {
    var color: Color
    var companion = DistributionStyle.ground
    var power = 0.0
    var frozen = true
    var phase = 0.0
    var contact = CGSize.zero
    var strength = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var heldTime = Date.now.timeIntervalSinceReferenceDate

    var body: some View {
        let moving = visible && abs(power) > 0.025 && !frozen && !reduceMotion && scenePhase == .active
        TimelineView(.animation(minimumInterval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.0 / 20 : 1.0 / 60, paused: !moving)) { clock in
            let time = (moving ? clock.date.timeIntervalSinceReferenceDate : heldTime).truncatingRemainder(dividingBy: 4096)
            DistributionFoldInk(color: color, companion: companion, power: moving ? abs(power) : 0,
                                phase: phase, time: time, contact: contact, strength: strength)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: moving) { _, active in if !active { heldTime = Date.now.timeIntervalSinceReferenceDate } }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private nonisolated struct DistributionFoldInk: View, Animatable {
    var color, companion: Color
    var power, phase, time: Double
    var contact: CGSize
    var strength: Double
    var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(phase, AnimatablePair(contact.width, contact.height)) }
        set { phase = newValue.first; contact = CGSize(width: newValue.second.first, height: newValue.second.second) }
    }
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(DistributionStyle.eye)
                .colorEffect(ShaderLibrary.ftwFold(
                    .float2(geometry.size), .float4(phase, time, power, strength),
                    .float2(contact.width, contact.height), .color(color), .color(companion),
                    .color(DistributionStyle.ground), .color(DistributionStyle.eye)))
        }
    }
}

struct DistributionHeader<Content: View>: View {
    var color: Color
    var companion = DistributionStyle.ground
    var power = 0.0
    var phase = 0.0
    var strength = 1.0
    var bottomSpace = 30.0
    @ViewBuilder var content: (CGSize) -> Content
    @Environment(DistributionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pull = CGSize.zero
    @State private var grabbing = false
    var body: some View {
        content(pull).padding(26).padding(.bottom, bottomSpace)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DistributionMaterial(color: color, companion: companion, power: power,
                                             frozen: model.frozen, phase: phase, contact: pull, strength: strength))
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard !reduceMotion, !model.frozen,
                          grabbing || abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                    grabbing = true
                    pull = CGSize(width: tanh(value.translation.width / 160) * 110,
                                  height: tanh(value.translation.height / 160) * 45)
                }
                .onEnded { _ in
                    grabbing = false
                    withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.53)) { pull = .zero }
                })
            .sensoryFeedback(.impact(weight: .light), trigger: grabbing) { _, new in new }
            .onChange(of: model.frozen) { _, frozen in if frozen { pull = .zero; grabbing = false } }
    }
}

struct DistributionHistoryMaterial: View, @MainActor Animatable {
    var share: Double
    var phase: Double
    var top, bottom: Color
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(share, phase) }
        set { share = newValue.first; phase = newValue.second }
    }
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(DistributionStyle.eye)
                .colorEffect(ShaderLibrary.ftwHistory(.float2(geometry.size), .float(share), .float(phase),
                                                    .color(top), .color(bottom), .color(DistributionStyle.eye)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A plan is held across time slots. Broad rounded volumes share one
/// baseline instead of drawing pointed, interpolated peaks between slots.
struct DistributionPlanMaterial: View, @MainActor Animatable {
    var powers: [Double]
    var selection: Double
    var contactY: Double
    var grip: Double
    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(selection, AnimatablePair(contactY, grip)) }
        set { selection = newValue.first; contactY = newValue.second.first; grip = newValue.second.second }
    }
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(DistributionStyle.eye)
                .colorEffect(ShaderLibrary.ftwPlan(
                    .float2(geometry.size), .float4(powers[0], powers[1], powers[2], powers[3]),
                    .float4((selection + 0.5) / 4, contactY, grip, 0),
                    .color(DistributionStyle.cyan), .color(DistributionStyle.ground), .color(DistributionStyle.eye)))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension DistributionScreen {
    var materialInk: Color {
        switch self {
        case .car, .plan, .access, .invite: DistributionStyle.purpleInk
        case .solar, .prices, .notifications, .pair, .scan: DistributionStyle.goldInk
        case .battery, .history, .recovery, .widgets: DistributionStyle.cyanInk
        case .home, .about, .licenses: DistributionStyle.homeInk
        default: DistributionStyle.greenInk
        }
    }
    var materialColor: Color {
        switch self {
        case .car, .plan, .access, .invite: DistributionStyle.purple
        case .solar, .prices, .notifications, .pair, .scan: DistributionStyle.gold
        case .battery, .history, .recovery, .widgets: DistributionStyle.cyan
        case .home, .about, .licenses: DistributionStyle.home
        default: DistributionStyle.green
        }
    }
}

/// A quiet continuation of the header, without a new enclosing card.
struct DistributionSection: ViewModifier {
    var color: Color
    var phase = 0.0
    func body(content: Content) -> some View {
        content.padding(24)
            .background(DistributionMaterial(color: color, phase: phase, strength: 0.23))
    }
}

struct DistributionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1, anchor: .center)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.63), value: configuration.isPressed)
    }
}

/// A stored level has a still rounded fill, not an animated live current.
struct DistributionLevel: View {
    var value: Double
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DistributionStyle.line.opacity(0.35))
                Capsule().fill(color.gradient)
                    .overlay(alignment: .top) { Capsule().fill(DistributionStyle.eye.opacity(0.35)).frame(height: 3).padding(.horizontal, 10).padding(.top, 3) }
                    .frame(width: max(14, geometry.size.width * min(1, max(0, value))))
                    .shadow(color: color.opacity(0.35), radius: 6, y: 4)
            }
        }.frame(height: 18)
            .animation(reduceMotion ? nil : DistributionStyle.motion, value: value)
            .accessibilityHidden(true)
    }
}
#endif
