import FTWShared
import SwiftUI

/// The next 24 hours on the dial. The Crown steps the hand a quarter hour
/// at a time with a tick for each, and a light tap at now, at the edges of
/// the cheapest hours and at the car's goal. The middle shows that
/// quarter's time and price, and the line under the dial says what is
/// planned. A tap on the dial brings the hand back to now.
struct PlanPage: View {
    let model: WatchModel
    @State private var quarter = 0
    @State private var scrub = ScrubStep()
    @State private var faces = DialMemo()
    @FocusState private var focused: Bool

    var body: some View {
        // The hand and the words move by the minute, never by the second.
        TimelineView(.everyMinute) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let ctx = model.context
            let dial = faces.dial(plan: ctx?.plan, prices: ctx?.prices, nowMs: nowMs)
            let moment = PlanGlance.moment(ctx?.plan.map { CacheRead(record: $0, origin: .app) }, atMs: nowMs)
            let i = min(max(quarter, 0), WatchDial.count - 1)
            GeometryReader { geo in
                // The dial takes what the two lines under it leave.
                let side = max(80, min(geo.size.width - 4, geo.size.height - 30))
                VStack(spacing: 2) {
                    ZStack {
                        DialFace(dial: dial, selected: i, grey: moment.isGrey)
                        VStack(spacing: 0) {
                            Text(dial.time(i))
                                .font(Theme.figure(side * 0.15))
                                .foregroundStyle(Theme.ink)
                            Text(dial.price(i).uppercased())
                                .font(.system(size: max(8, side * 0.062), weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink2)
                        }
                        .accessibilityHidden(true)
                    }
                    .frame(width: side, height: side)
                    .contentShape(Circle())
                    .onTapGesture {
                        quarter = 0
                        focused = true
                    }
                    Text(i == 0 ? next(moment) : dial.what(i))
                        .font(.system(size: 12))
                        .foregroundStyle(i == 0 && moment.isGrey ? Theme.ink3 : Theme.ink2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                        .minimumScaleFactor(0.85)
                    if let age = planAge(ctx?.plan, moment: moment) {
                        Text(age)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .focusable()
            .focused($focused)
            .digitalCrownRotation(detent: $quarter, from: 0, through: WatchDial.count - 1, by: 1, sensitivity: .high, isContinuous: false, isHapticFeedbackEnabled: false)
            .onChange(of: quarter) { _, q in
                scrub.move(to: q, landmark: dial.landmarks.contains(q))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WatchWord.planTitle.text)
            .accessibilityValue("\(dial.time(i)), \(dial.price(i)), \(i == 0 ? moment.summary : dial.what(i))")
            .accessibilityHint(WatchWord.turnTheCrown.text)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: quarter = min(quarter + 1, WatchDial.count - 1)
                case .decrement: quarter = max(quarter - 1, 0)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("watch.plan.dial")
        }
        .sensoryFeedback(.selection, trigger: scrub.ticks)
        .sensoryFeedback(.impact(weight: .light), trigger: scrub.bumps)
        .navigationTitle(WatchWord.planTitle.text)
        .task {
            // Focus once the page is on screen, so the Crown turns the hand
            // rather than the pages.
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
        .onAppear {
            #if DEBUG
            // `-FTWWatchQuarter 12` opens with the hand moved, for screenshots.
            let q = UserDefaults.standard.integer(forKey: "FTWWatchQuarter")
            if q > 0 { quarter = q }
            #endif
        }
    }

    /// What happens next, in one short sentence: "Batteriet laddar ur till
    /// 19:30". The whole plan is the dial.
    private func next(_ m: PlanGlance.Moment) -> String {
        guard let what = m.nextWhat else { return m.summary }
        return [what, m.nextUntil].compactMap { $0 }.joined(separator: " ")
    }

    /// "PLANNED 16:45", or "PLAN FROM 14:05" once it is old.
    private func planAge(_ plan: CacheRecord<PlanEntry>?, moment: PlanGlance.Moment) -> String? {
        guard let plan else { return nil }
        let at = ZoneClock.of(moment.timeZone).label(plan.readAtMs)
        return (moment.state == .old ? WatchWord.planFrom : WatchWord.planned).format(at)
    }
}

/// The dial worked out once per plan and minute, so a turn of the Crown
/// only reads it.
@Observable
@MainActor
final class DialMemo {
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var kept: WatchDial?

    func dial(plan: CacheRecord<PlanEntry>?, prices: CacheRecord<PriceEntry>?, nowMs: Double) -> WatchDial {
        let minute = (nowMs / 60_000).rounded(.down)
        let key = "\(plan?.readAtMs ?? 0)|\(prices?.readAtMs ?? 0)|\(minute)"
        if key == self.key, let kept { return kept }
        let d = WatchDial(plan: plan?.value, prices: prices?.value, nowMs: nowMs)
        self.key = key
        kept = d
        return d
    }
}
