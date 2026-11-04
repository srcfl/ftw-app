import FTWShared
import SwiftUI

/// The plan on the dial: the next twelve hours. The Crown steps the hand a
/// quarter hour at a time with a tick for each, and on past the twelve
/// hours the face melts into the next twelve, into the rest of the plan,
/// and back the same way; a light tap
/// at now, at the edges of the cheapest hours and at the car's goal. The
/// middle shows that quarter's time and price, and the line under the dial
/// says what is planned. A tap on the dial brings the hand back to now.
struct PlanPage: View {
    let model: WatchModel
    /// Quarters on from now, as far as the plan reaches.
    @State private var quarter = 0
    @State private var scrub = ScrubStep()
    @State private var faces = DialMemo()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The hand and the words move by the minute, never by the second.
        TimelineView(.everyMinute) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let ctx = model.context
            let place = faces.place(quarter, plan: ctx?.plan, prices: ctx?.prices, nowMs: nowMs)
            let dial = place.dial
            let moment = PlanGlance.moment(ctx?.plan.map { CacheRead(record: $0, origin: .app) }, atMs: nowMs)
            let i = place.index
            GeometryReader { geo in
                // The dial takes what the two lines under it leave.
                let side = max(80, min(geo.size.width - 4, geo.size.height - 30))
                VStack(spacing: 2) {
                    ZStack {
                        // Across the seam the one face melts into the next.
                        ZStack {
                            PlanDialFace(dial: dial, grey: moment.isGrey)
                                .equatable()
                                .id(dial.offset)
                                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                        }
                        .animation(Theme.spring, value: dial.offset)
                        PlanDialHand(dial: dial, selected: i)
                        VStack(spacing: 0) {
                            // Tomorrow over the time, on a line kept so
                            // the time never moves.
                            Text(dial.day(i) ?? " ")
                                .font(.system(size: max(8, side * 0.062), weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink2)
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
                    Text(place.step == 0 ? next(moment) : dial.what(i))
                        .font(.system(size: 12))
                        .foregroundStyle(place.step == 0 && moment.isGrey ? Theme.ink3 : Theme.ink2)
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
            .digitalCrownRotation(detent: $quarter, from: 0, through: place.steps - 1, by: 1, sensitivity: .high, isContinuous: false, isHapticFeedbackEnabled: false)
            .onChange(of: quarter) { _, q in
                let landed = faces.place(q, plan: ctx?.plan, prices: ctx?.prices, nowMs: nowMs)
                scrub.move(to: q, landmark: landed.dial.landmarks.contains(landed.index))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(WatchWord.planTitle.text)
            .accessibilityValue("\(dial.when(i)), \(dial.price(i)), \(place.step == 0 ? moment.summary : dial.what(i))")
            .accessibilityHint(WatchWord.turnTheCrown.text)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: quarter = min(quarter + 1, place.steps - 1)
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

/// The dial worked out once per plan and minute, to the end of the plan,
/// so a turn of the Crown only reads it and winds the face.
@Observable
@MainActor
final class DialMemo {
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var kept: PlanDial?

    /// Where the Crown is: `quarter` quarters on from now, held to the
    /// plan's reach, on the face of the twelve hours that hold it.
    func place(_ quarter: Int, plan: CacheRecord<PlanEntry>?, prices: CacheRecord<PriceEntry>?, nowMs: Double) -> (dial: PlanDial, index: Int, step: Int, steps: Int) {
        let minute = (nowMs / 60_000).rounded(.down)
        let key = "\(plan?.readAtMs ?? 0)|\(prices?.readAtMs ?? 0)|\(minute)"
        if key != self.key || kept == nil {
            self.key = key
            let zone = (plan?.value.timeZone ?? prices?.value.timeZone).flatMap(TimeZone.init(identifier:)) ?? .current
            let reach = plan.map { PlanGlance.reach($0.value, fromMs: nowMs, calendar: ZoneClock.of(zone).calendar) }
            kept = PlanDial(plan: plan?.value, prices: prices?.value, nowMs: nowMs, untilMs: reach)
        }
        let dial = kept!
        let q = min(max(quarter, 0), dial.quarters.count - 1)
        return (dial.wound(to: dial.offset(keeping: q)), q, q, dial.quarters.count)
    }
}
