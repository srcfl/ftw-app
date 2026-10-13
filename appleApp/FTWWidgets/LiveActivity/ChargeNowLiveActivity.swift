import ActivityKit
import FTWShared
import SwiftUI
import WidgetKit

/// "Charge now on since 14:02", with a timer from then and Back to the
/// plan. On the Lock Screen and in the Dynamic Island, and through `.small`
/// on a paired Apple Watch's Smart Stack and in CarPlay.
///
/// It names the state the box confirmed, not power: the hold can be on
/// while the car draws nothing. The phone starts it when the box confirms
/// Charge now and confirms it again on every read; past the stale date it
/// says when the box last confirmed it, the timer stops there, and every
/// view dims, the compact and minimal island included.
struct ChargeNowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeNowAttributes.self) { context in
            ChargeNowBanner(attributes: context.attributes, face: Self.face(context))
        } dynamicIsland: { context in
            let face = Self.face(context)
            return DynamicIsland {
                // The icon and the timer either side of the camera, the
                // words below it, where they have the whole width.
                DynamicIslandExpandedRegion(.leading) {
                    Bolt(dimmed: face.dimmed)
                        .font(.title2)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(face: face)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Headline(face: face)
                        Subtitle(face: face)
                        BackToPlan(attributes: context.attributes)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Bolt(dimmed: face.dimmed)
            } compactTrailing: {
                Elapsed(face: face)
                    .frame(maxWidth: 58)
            } minimal: {
                Bolt(dimmed: face.dimmed)
            }
            // The island is always dark.
            .keylineTint(face.dimmed ? Color.secondary : Tone.accent.dark)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Bolt(dimmed: face.dimmed).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Headline(face: face)
                    Subtitle(face: face)
                }
                // The words first; the timer takes what is left.
                .layoutPriority(1)
                Spacer(minLength: 8)
                Elapsed(face: face)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: 96, alignment: .trailing)
            }
            if !dim {
                BackToPlan(attributes: attributes)
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
            // The watch's card is narrow: the timer gets the top line, the
            // words the one below it.
            HStack(spacing: 6) {
                Bolt(dimmed: face.dimmed)
                Elapsed(face: face)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(face.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if !dim {
                BackToPlan(attributes: attributes)
                    .font(.caption)
            }
        }
        .padding(10)
    }
}

/// "Charge now on since 14:02", or, stale, "Last confirmed 14:17 · open
/// FTW", on one line.
private struct Headline: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        Text(face.headline)
            .font(.headline)
            .foregroundStyle(face.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// "No time limit", or, stale, that it may have changed since.
private struct Subtitle: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        Text(face.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Time since the box confirmed Charge now: counting while current,
/// stopped at the last confirmation once stale.
private struct Elapsed: View {
    let face: ChargeNowActivity.Face

    var body: some View {
        timer
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(face.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.accent))
            // A stopped timer is a fixed figure: it keeps its width beside
            // the longer stale headline.
            .fixedSize(horizontal: isStopped, vertical: false)
    }

    private var isStopped: Bool {
        if case .stopped = face.timer { return true }
        return false
    }

    private var timer: Text {
        switch face.timer {
        case .running(let from):
            return Text(timerInterval: from...Date.distantFuture, countsDown: false)
        case .stopped(let from, let at):
            return Text(timerInterval: from...max(from, at), pauseTime: at, countsDown: false)
        }
    }
}

private struct Bolt: View {
    let dimmed: Bool
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        Image(systemName: dimmed ? "bolt.car" : "bolt.car.fill")
            .foregroundStyle(dim || dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.accent))
    }
}

/// The one command here. It names its home, asks for the unlocked phone and
/// runs in the app, which ends this Live Activity when the box confirms.
private struct BackToPlan: View {
    let attributes: ChargeNowAttributes

    var body: some View {
        Button(intent: BackToPlanIntent(loadpointID: attributes.loadpointID, home: attributes.home)) {
            Label(ChargeNowActivity.backToPlan, systemImage: "calendar")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Tone.accent)
    }
}
