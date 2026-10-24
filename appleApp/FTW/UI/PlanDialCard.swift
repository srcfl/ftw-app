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
/// The ring has no gesture of its own: any gesture there, even one beside
/// the scroll's, held the page still for every swipe that started on the
/// ring (the simulator showed it for a drag, a long press, raw touches and
/// a 6 pt drag alike). The page takes every touch beside its scroll and
/// hands it here (`DialTouch`); the dial asks whether it started on the
/// ring.
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
    /// The page's touches, handed on.
    let touch: DialTouch

    @State private var scrub = ScrubModel()
    /// The quarter the finger was last on, so it cannot wind past the seam.
    /// Written on every drag event and read by nothing that draws.
    @State private var finger = Finger()
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
        // Where the dial is on the screen, for the page's touches: written
        // to a plain reference, so a scroll redraws nothing here.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { finger.frame = $0 }
        .onChange(of: dial, initial: true) { _, now in finger.dial = now }
        .onAppear {
            touch.take(finger, changed: { value in
                // A new touch has a new start; one the system took away
                // never ended.
                if finger.startAt != value.startLocation {
                    end()
                    start(value)
                }
                move(value)
            }, ended: { end() })
        }
        .onDisappear {
            touch.release(finger)
            end()
        }
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

    /// The dial's side and its centre in its own frame, which is the whole
    /// width the dial sits in.
    private var side: CGFloat { min(finger.frame.width, finger.frame.height) }
    private var centre: CGPoint { CGPoint(x: finger.frame.width / 2, y: finger.frame.height / 2) }

    /// Where a point on the screen sits in the dial's frame.
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - finger.frame.minX, y: p.y - finger.frame.minY)
    }

    /// A finger came down somewhere on the page. The dial takes it only on
    /// the ring (`DialRing`), and never within 20 pt of the screen's
    /// leading edge, where the back swipe starts.
    private func start(_ v: DragGesture.Value) {
        finger.startAt = v.startLocation
        finger.startMs = ProcessInfo.processInfo.systemUptime * 1000
        finger.decision = nil
        guard v.startLocation.x >= EdgeRule.edge, DialRing.contains(local(v.startLocation), in: CGRect(origin: .zero, size: finger.frame.size)) else {
            finger.decision = .pass
            return
        }
        finger.hold = Task {
            try? await Task.sleep(for: .milliseconds(Int(RingIntent.holdMs)))
            guard !Task.isCancelled else { return }
            rested()
        }
    }

    /// Each event costs a little arithmetic and writes nothing a view
    /// reads, until the touch is a scrub. A change of quarter moves the
    /// scrub model.
    private func move(_ v: DragGesture.Value) {
        let at = local(v.location)
        finger.last = at
        guard finger.decision == nil else {
            if finger.decision == .scrub { follow(at) }
            return
        }
        let ms = ProcessInfo.processInfo.systemUptime * 1000
        let held = ms - (finger.startMs ?? ms)
        let decision = RingIntent.decide(start: local(v.startLocation), now: at, centre: centre, heldMs: held)
        if decision != nil {
            DialLog.log.debug("dial decides after \(Int(held)) ms on a move of \(Double(v.translation.width), format: .fixed(precision: 1)), \(Double(v.translation.height), format: .fixed(precision: 1)) pt")
        }
        decide(decision, at: at)
    }

    /// No move came, and the finger rests on the ring: it scrubs.
    private func rested() {
        guard finger.decision == nil, let at = finger.last else { return }
        DialLog.log.debug("dial rested \(Int(RingIntent.holdMs)) ms")
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
        finger.startAt = nil
        finger.startMs = nil
        finger.decision = nil
        finger.last = nil
        finger.previous = nil
        if holds { holds = false }
        if scrub.isDown { withAnimation(Theme.spring) { scrub.lift() } }
    }

    private func follow(_ p: CGPoint) {
        let event = signposts.beginInterval("dial drag")
        defer { signposts.endInterval("dial drag", event) }
        guard side > 0 else { return }
        let now = finger.dial ?? dial
        let i = now.index(x: p.x - centre.x, y: p.y - centre.y, from: finger.previous)
        finger.previous = i
        guard i != scrub.index else { return }
        signposts.emitEvent("dial quarter")
        scrub.move(to: i, landmark: now.landmarks.contains(i))
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

/// The finger's last quarter, what its touch is, and where the dial sits:
/// a plain reference, so a touch or a scroll writes nothing SwiftUI
/// watches.
@MainActor
private final class Finger {
    var previous: Int?
    /// Where and when the touch came down, on the screen.
    var startAt: CGPoint?
    var startMs: Double?
    var decision: RingIntent.Decision?
    var last: CGPoint?
    var hold: Task<Void, Never>?
    /// On the screen.
    var frame: CGRect = .zero
    /// The dial on screen: the page's handler outlives a minute's dial.
    var dial: PlanDial?
}

/// The plan page's touches, handed to the dial or the lanes, whichever is
/// on screen: the page holds the one gesture, beside its scroll, and the
/// chart says what each touch is. `owner` is the chart that set the
/// handlers, so one leaving after the other came does not take them away.
@MainActor
final class DialTouch {
    var changed: ((DragGesture.Value) -> Void)?
    var ended: (() -> Void)?
    var owner: AnyObject?

    func take(_ owner: AnyObject, changed: @escaping (DragGesture.Value) -> Void, ended: @escaping () -> Void) {
        self.owner = owner
        self.changed = changed
        self.ended = ended
    }

    func release(_ owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        changed = nil
        ended = nil
    }
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

/// Where a finger scrubs: the ring of ticks and the rim, not the middle.
private enum DialRing {
    static func contains(_ p: CGPoint, in rect: CGRect) -> Bool {
        let side = min(rect.width, rect.height)
        let r = hypot(p.x - rect.midX, p.y - rect.midY)
        return r >= side * 0.26 && r <= side / 2
    }
}
