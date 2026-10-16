#if DEBUG && targetEnvironment(simulator)
import SwiftUI

nonisolated struct DistributionRobotAnchor {
    var bounds: Anchor<CGRect>
    var happy: Bool
    var gaze: Double
    var rotation: Double
    var frozen: Bool
}

nonisolated struct DistributionRobotAnchors: PreferenceKey {
    static var defaultValue: [DistributionScreen: DistributionRobotAnchor] { [:] }
    static func reduce(value: inout [DistributionScreen: DistributionRobotAnchor], nextValue: () -> [DistributionScreen: DistributionRobotAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private nonisolated struct DistributionRobotDestination: Equatable {
    var frame: CGRect?
    var screen: DistributionScreen
}

/// A place for the one persistent robot. Pages reserve space, not copies.
struct DistributionRobotMark: View {
    let screen: DistributionScreen
    var happy = false
    var gaze = 0.0
    var rotation = 0.0
    var frozen = false
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .anchorPreference(key: DistributionRobotAnchors.self, value: .bounds) { anchor in
                [screen: DistributionRobotAnchor(bounds: anchor, happy: happy, gaze: gaze, rotation: rotation, frozen: frozen)]
            }
            .accessibilityHidden(true)
    }
}

/// Stays outside the navigation transitions, so its eyes, motion and identity
/// continue while the destination's reserved place moves into view.
struct DistributionCompanion: View {
    let target: CGRect?
    let placement: DistributionRobotAnchor?
    @Environment(DistributionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = CGRect.zero
    @State private var route: DistributionScreen?
    @State private var travellingUntil = Date.distantPast
    @State private var travelGaze = 0.0

    var body: some View {
        DistributionRobot(happy: model.happy || (placement?.happy ?? false),
                          frozen: model.frozen || (placement?.frozen ?? false),
                          gaze: (placement?.gaze ?? model.gaze) + travelGaze)
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .rotationEffect(.degrees((placement?.rotation ?? 0) + travelGaze * 3))
            .position(x: frame.midX, y: frame.midY)
            .opacity(frame == .zero ? 0 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)
            .task(id: route) {
                guard route != nil, !reduceMotion else { return }
                do {
                    try await Task.sleep(for: .milliseconds(1100))
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { travelGaze = 0 }
                } catch {}
            }
            .onChange(of: DistributionRobotDestination(frame: target, screen: model.visibleScreen), initial: true) { _, destination in
                guard let next = destination.frame, next.width >= 48, next.width <= 230, next.height.isFinite else { return }
                let first = frame == .zero
                let changingRoute = route != model.visibleScreen
                if changingRoute {
                    route = model.visibleScreen
                    travellingUntil = Date.now.addingTimeInterval(0.9)
                    travelGaze = first || reduceMotion ? 0 : max(-1.5, min(1.5, (next.midX - frame.midX) / 100))
                }
                let travelling = Date.now < travellingUntil
                let animation: Animation? = first || reduceMotion ? nil : travelling
                    ? .spring(response: 0.78, dampingFraction: 0.81)
                    : model.visibleScreen == .now ? nil : .interactiveSpring(response: 0.35, dampingFraction: 0.83)
                withAnimation(animation) { frame = next }
            }
    }
}
#endif
