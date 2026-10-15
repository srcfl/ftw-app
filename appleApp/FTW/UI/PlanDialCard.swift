import FTWKit
import os
import SwiftUI

/// Points of interest for Instruments: each drag event on the dial, and
/// each change of the quarter under the finger.
private let signposts = OSSignposter(subsystem: "energy.ftw.app", category: .pointsOfInterest)

/// The plan dial at the top of the plan view: the next 24 hours as one
/// turn, the time and the price in the middle. A finger dragged round the
/// ring reads the plan a quarter at a time: the hand follows, brackets
/// close on its tick, the middle shows that quarter, `.selection` ticks per
/// quarter and a light impact marks now, the cheapest hours' edges and the
/// car's goal. On lift the hand springs back to now. VoiceOver steps it an
/// hour at a time.
///
/// The dial sits in the plan's scroll, so a finger on the ring scrubs only
/// once it moves along the ring or rests 0.1 s (`RingIntent`); a move up or
/// down, or across the ring, scrolls the page. While it scrubs, the page
/// holds still (`holds`). The screen's leading 20 pt are the back swipe's.
///
/// The face never sees the finger. Only the hand and the middle read the
/// scrub model, so a drag redraws those two, once per quarter.
struct PlanDialCard: View {
    let dial: PlanDial
    /// The plan is old or the box could not plan.
    let grey: Bool
    /// The dial before the person's last change, while its plan stands.
    var fade: DialFade?
    /// True while a finger scrubs: the page around holds still.
    @Binding var holds: Bool

    @State private var scrub = ScrubModel()
    /// The quarter the finger was last on, so it cannot wind past the seam.
    /// Written on every drag event and read by nothing that draws.
    @State private var finger = Finger()
    /// The dial's frame, which may be wider than the dial, and how far in
    /// from the screen's leading edge it sits. Neither moves as the page
    /// scrolls, so a scroll redraws nothing here.
    @State private var size: CGSize = .zero
    @State private var minX: CGFloat = 0
    @GestureState private var touching = false
    /// Where VoiceOver has stepped to.
    @State private var spoken: Int?

    var body: some View {
        ZStack {
            PlanDialFace(dial: dial, grey: grey)
                .equatable()
            if let fade {
                MovedFade(fresh: fade.fresh, mask: QuarterWedges(dial: fade.old, quarters: fade.moved)) {
                    PlanDialFace(dial: fade.old, grey: grey)
                        .equatable()
                }
                .id(fade.atMs)
            }
            DialHand(dial: dial, model: scrub)
            DialCentre(dial: dial, model: scrub, spoken: spoken)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX = $0 }
        // Only the ring takes a finger, so a drag from the middle scrolls
        // the page; and none within 20 pt of the screen's leading edge.
        .contentShape(DialRing(leading: EdgeRule.inset(minX: minX)), eoFill: true)
        // Beside the scroll, never instead of it: the ring decides.
        .simultaneousGesture(drag)
        .onChange(of: touching) { _, now in if !now { end() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PlanDial.title)
        .accessibilityValue(spokenValue(spoken ?? 0))
        .accessibilityHint(L("Swipe up or down to move an hour."))
        .accessibilityAdjustableAction { step($0) }
        .accessibilityIdentifier("plan.dial")
        #if DEBUG
        .task { await autoScrub() }
        #endif
    }

    /// The dial's side and its centre in the gesture's space, which is the
    /// whole width the dial sits in.
    private var side: CGFloat { min(size.width, size.height) }
    private var centre: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    /// Each drag event costs a little arithmetic and one lookup and writes
    /// nothing a view reads, until the touch is a scrub. A change of
    /// quarter moves the scrub model.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { touch($0) }
            .onEnded { _ in end() }
    }

    private func touch(_ v: DragGesture.Value) {
        let ms = ProcessInfo.processInfo.systemUptime * 1000
        if finger.startMs == nil {
            finger.startMs = ms
            finger.decision = nil
            finger.hold = Task {
                try? await Task.sleep(for: .milliseconds(Int(RingIntent.holdMs)))
                guard !Task.isCancelled else { return }
                rested()
            }
        }
        finger.last = v.location
        guard finger.decision == nil else {
            if finger.decision == .scrub { follow(v.location) }
            return
        }
        decide(RingIntent.decide(start: v.startLocation, now: v.location, centre: centre, heldMs: ms - (finger.startMs ?? ms)), at: v.location)
    }

    /// No move came, and the finger rests on the ring: it scrubs.
    private func rested() {
        guard finger.decision == nil, let at = finger.last else { return }
        decide(.scrub, at: at)
    }

    private func decide(_ decision: RingIntent.Decision?, at p: CGPoint) {
        guard let decision else { return }
        finger.decision = decision
        finger.hold?.cancel()
        switch decision {
        case .scrub:
            DialLog.log.debug("dial scrubs")
            holds = true
            follow(p)
        case .pass:
            DialLog.log.debug("dial passes the touch to the page")
        }
    }

    private func end() {
        guard finger.startMs != nil else { return }
        finger.hold?.cancel()
        finger.hold = nil
        finger.startMs = nil
        finger.decision = nil
        finger.last = nil
        finger.previous = nil
        holds = false
        withAnimation(Theme.spring) { scrub.lift() }
    }

    private func follow(_ p: CGPoint) {
        let event = signposts.beginInterval("dial drag")
        defer { signposts.endInterval("dial drag", event) }
        guard side > 0 else { return }
        let i = dial.index(x: p.x - centre.x, y: p.y - centre.y, from: finger.previous)
        finger.previous = i
        guard i != scrub.index else { return }
        signposts.emitEvent("dial quarter")
        scrub.move(to: i, landmark: dial.landmarks.contains(i))
    }

    // MARK: VoiceOver

    /// An hour a step, from now to the end of the turn and back.
    private func step(_ direction: AccessibilityAdjustmentDirection) {
        let at = spoken ?? 0
        switch direction {
        case .increment: spoken = min(PlanDial.count - 1, at + 4)
        case .decrement: spoken = max(0, at - 4)
        @unknown default: return
        }
    }

    /// "14:00, 98 öre/kWh, battery stores 3.0 kW".
    private func spokenValue(_ i: Int) -> String {
        [dial.time(i), dial.price(i), dial.what(i)].joined(separator: ", ")
    }

    #if DEBUG
    /// With `-FTWDialScrub YES`, a finger goes once round the ring and back
    /// through the same path a touch takes, for recordings and frame
    /// measurements where nothing can touch.
    private func autoScrub() async {
        guard UserDefaults.standard.bool(forKey: "FTWDialScrub") else { return }
        try? await Task.sleep(for: .seconds(2))
        let began = ContinuousClock.now
        let r = side * 0.42
        while ContinuousClock.now - began < .seconds(12) {
            let t = (ContinuousClock.now - began) / .milliseconds(6_000)
            let along = t < 1 ? t : 2 - t
            let a = dial.seam + 0.01 + along * (2 * .pi - 0.02)
            follow(CGPoint(x: centre.x + r * sin(a), y: centre.y - r * cos(a)))
            try? await Task.sleep(for: .milliseconds(8))
        }
        finger.previous = nil
        withAnimation(Theme.spring) { scrub.lift() }
    }
    #endif
}

/// The finger's last quarter, and what its touch is: a plain reference, so
/// a drag event writes nothing SwiftUI watches.
@MainActor
private final class Finger {
    var previous: Int?
    var startMs: Double?
    var decision: RingIntent.Decision?
    var last: CGPoint?
    var hold: Task<Void, Never>?
}

private enum DialLog {
    static let log = Logger(subsystem: "energy.ftw.app", category: "scrub")
}

/// The hand and the lock-on, the only marks that move with a finger.
/// Haptics ride here too, in the same update as the quarter.
private struct DialHand: View {
    let dial: PlanDial
    let model: ScrubModel

    var body: some View {
        PlanDialHand(dial: dial, selected: model.index)
            .sensoryFeedback(.selection, trigger: model.ticks)
            .sensoryFeedback(.impact(weight: .light), trigger: model.bumps)
    }
}

/// The middle: the time at 40 pt, the price in mono, and a third line kept
/// for what the plan does in the quarter under the finger.
private struct DialCentre: View {
    let dial: PlanDial
    let model: ScrubModel
    let spoken: Int?

    var body: some View {
        let i = model.index ?? spoken ?? 0
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: side * 0.008) {
                Text(dial.time(i))
                    .font(Theme.figure(side * 0.118))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                Text(dial.prices[i])
                    .font(.system(size: max(9, side * 0.031), weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink2)
                // Kept whether or not a finger is down, so nothing moves.
                Text(model.index == nil ? " " : dial.doing[i])
                    .font(.system(size: max(9, side * 0.031), weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: side * 0.5)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}

/// Where a finger scrubs: the ring of ticks and the rim, not the middle,
/// and nothing in the leading `leading` points.
private struct DialRing: Shape {
    var leading: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let inner = side * 0.26
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
        path.addEllipse(in: CGRect(x: rect.midX - inner, y: rect.midY - inner, width: inner * 2, height: inner * 2))
        guard leading > 0 else { return path }
        return path.intersection(EdgeClear(leading: leading).path(in: rect), eoFill: true)
    }
}
