import ActivityKit
import FTWShared
import SwiftUI
import WidgetKit

/// Charge now outside the app, in the manner of the best travel apps: one
/// line that says what is happening now, a large time in even digits, and
/// the receipt log `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED`, each slot lit
/// on its own evidence. On the Lock Screen and in the Dynamic Island, and
/// through `.small` on a paired Apple Watch's Smart Stack and in CarPlay.
///
/// It names the state the box confirmed, not power: the hold can be on
/// while the car draws nothing, and MEASURED says when it did. Two minutes
/// after the last confirmation it says when that was, the time stops
/// there, and everything dims. Every state has the same layout, so a
/// change fades in place: the island keeps its size and nothing jumps. It
/// sits on FTW's ground, never glows: a card is not a live reading.
struct ChargeNowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeNowAttributes.self) { context in
            ChargeNowBanner(attributes: context.attributes, face: Self.face(context))
                .activityBackgroundTint(Theme.ground)
                .activitySystemActionForegroundColor(Theme.ink)
        } dynamicIsland: { context in
            let face = Self.face(context)
            return DynamicIsland {
                // Expanded, three things: the time, what is happening, and
                // how far it has come.
                DynamicIslandExpandedRegion(.leading) {
                    Bolt(face: face)
                        .font(.title2)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(face: face)
                        .font(Theme.figure(28))
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Headline(face: face)
                        ReceiptRow(receipt: face.receipt, dimmed: face.dimmed)
                            .padding(.vertical, 2)
                        BackToPlan(attributes: context.attributes, face: face)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Bolt(face: face)
            } compactTrailing: {
                // One thing, at one width in every state.
                Elapsed(face: face)
                    .frame(width: 56, alignment: .trailing)
            } minimal: {
                Bolt(face: face)
            }
            // The island is always dark.
            .keylineTint(Theme.fixed(face.dimmed ? Theme.ink3 : Theme.car, .dark))
        }
        .supplementalActivityFamilies([.small])
    }

    static func face(_ context: ActivityViewContext<ChargeNowAttributes>) -> ChargeNowActivity.Face {
        ChargeNowActivity.face(context.state, stale: context.isStale, zone: context.attributes.zone)
    }
}

/// The Lock Screen's banner, and the watch's and CarPlay's smaller one.
struct ChargeNowBanner: View {
    let attributes: ChargeNowAttributes
    let face: ChargeNowActivity.Face
    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        switch family {
        case .small: ChargeNowSmall(attributes: attributes, face: face)
        default: medium
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Bolt(face: face).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    // The card's height is capped: what is happening keeps
                    // its lines before the line under it.
                    Headline(face: face).layoutPriority(1)
                    Subtitle(face: face)
                }
                // The words first; the time takes what is left.
                .layoutPriority(1)
                Spacer(minLength: 8)
                // A stopped time is smaller, so the stale words fit beside
                // it on a narrow phone.
                Elapsed(face: face)
                    .font(Theme.figure(face.dimmed ? 22 : 34))
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            ReceiptRow(receipt: face.receipt, dimmed: face.dimmed)
            if !dim {
                BackToPlan(attributes: attributes, face: face)
            }
        }
        .padding(16)
    }
}

/// Smart Stack on the watch and CarPlay: the same facts, tighter.
struct ChargeNowSmall: View {
    let attributes: ChargeNowAttributes
    let face: ChargeNowActivity.Face
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The watch's card is narrow: the time gets the top line, the
            // words the one below it.
            HStack(spacing: 6) {
                Bolt(face: face)
                Elapsed(face: face)
                    .font(Theme.figure(17))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(face.headline)
                .font(.caption)
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .contentTransition(.interpolate)
            ReceiptRow(receipt: face.receipt, dimmed: face.dimmed, size: 9)
            if !dim {
                BackToPlan(attributes: attributes, face: face)
                    .font(.caption)
            }
        }
        .padding(10)
    }
}

/// What is happening now, in one line: "Charge now on since 14:02",
/// "Sending Charge now…", or, stale, "Last confirmed 14:17 · open FTW".
private struct Headline: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        Text(face.headline)
            .font(.headline)
            .foregroundStyle(face.dimmed ? Theme.ink2 : Theme.ink)
            .lineLimit(face.dimmed ? 2 : 1)
            .minimumScaleFactor(0.8)
            .contentTransition(.interpolate)
    }
}

/// "No time limit", what it waits for, or, stale, that it may have changed.
private struct Subtitle: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        Text(face.subtitle)
            .font(.subheadline)
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.interpolate)
    }
}

/// Time since the box confirmed Charge now: an ellipsis while the command
/// is on its way, counting once it is on, stopped at the last confirmation
/// once stale.
private struct Elapsed: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        timer
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(face.dimmed || face.timer == .waiting ? Theme.ink3 : Theme.car)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: false))
            // Plain text has its own width; the stale headline beside it
            // wraps instead of squeezing the time.
            .fixedSize(horizontal: isStatic, vertical: false)
    }

    private var isStatic: Bool {
        if case .running = face.timer { return false }
        return true
    }

    /// A stopped timer is plain text: a paused timer text still asks for
    /// the width of a running one, which pushes everything else out.
    private var timer: Text {
        switch face.timer {
        case .waiting:
            return Text("…")
        case .running(let from):
            return Text(timerInterval: from...Date.distantFuture, countsDown: false)
        case .stopped(let from, let at):
            let seconds = max(0, at.timeIntervalSince(from))
            return Text(Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
    }
}

/// The car with a bolt: filled while Charge now is on or on its way, an
/// outline once stale. The change is the symbol's own.
private struct Bolt: View {
    let face: ChargeNowActivity.Face
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        Image(systemName: face.dimmed ? "bolt.car" : "bolt.car.fill")
            .foregroundStyle(dim || face.dimmed ? Theme.ink3 : Theme.car)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The one command here. It names its home, asks for the unlocked phone and
/// runs in the app, which ends this Live Activity when the box confirms.
/// It keeps its place while Charge now is on its way, quieter.
private struct BackToPlan: View {
    let attributes: ChargeNowAttributes
    let face: ChargeNowActivity.Face

    var body: some View {
        Button(intent: BackToPlanIntent(loadpointID: attributes.loadpointID, home: attributes.home)) {
            Label(ChargeNowActivity.backToPlan, systemImage: "calendar")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Theme.ink)
        .opacity(face.receipt.confirmed ? 1 : 0.5)
    }
}
