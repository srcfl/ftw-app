import ActivityKit
import FTWShared
import SwiftUI
import WidgetKit

/// "Charging now since 14:02", with a timer from then and Back to the plan.
/// On the Lock Screen and in the Dynamic Island, and through `.small` on a
/// paired Apple Watch's Smart Stack and in CarPlay.
///
/// Static words and a timer only. The phone starts this when the box
/// confirms Charge now and ends it when the box confirms Back to the plan;
/// in between nothing reads the charger, so nothing here claims power or a
/// level. After the stale date it says when the box last confirmed it.
struct ChargeNowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeNowAttributes.self) { context in
            ChargeNowBanner(attributes: context.attributes, state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(ChargeNowActivity.title)
                    } icon: {
                        Bolt()
                    }
                    .font(.headline)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(state: context.state)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Subtitle(attributes: context.attributes, state: context.state, isStale: context.isStale)
                        BackToPlan(loadpointID: context.attributes.loadpointID)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Bolt()
            } compactTrailing: {
                Elapsed(state: context.state)
                    .frame(maxWidth: 58)
            } minimal: {
                Bolt()
            }
            // The island is always dark.
            .keylineTint(Tone.accent.dark)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The Lock Screen's banner, and the watch's and CarPlay's smaller one.
struct ChargeNowBanner: View {
    let attributes: ChargeNowAttributes
    let state: ChargeNowActivity.State
    let isStale: Bool
    @Environment(\.activityFamily) private var family
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        switch family {
        case .small: small
        default: medium
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Bolt().font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChargeNowActivity.since(state, zone: attributes.zone))
                        .font(.headline)
                    Subtitle(attributes: attributes, state: state, isStale: isStale)
                }
                Spacer(minLength: 8)
                Elapsed(state: state)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: 110, alignment: .trailing)
            }
            if !dim {
                BackToPlan(loadpointID: attributes.loadpointID)
            }
        }
        .padding(16)
    }

    /// Smart Stack on the watch and CarPlay: the same facts, tighter.
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Bolt()
                Text(ChargeNowActivity.title).font(.headline)
                Spacer(minLength: 4)
                Elapsed(state: state).font(.headline)
            }
            Text(isStale ? ChargeNowActivity.confirmed(state, zone: attributes.zone) : ChargeNowActivity.sinceShort(state, zone: attributes.zone))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !dim {
                BackToPlan(loadpointID: attributes.loadpointID)
                    .font(.caption)
            }
        }
        .padding(10)
    }
}

/// "No time limit", or, once stale, when the box last confirmed it.
private struct Subtitle: View {
    let attributes: ChargeNowAttributes
    let state: ChargeNowActivity.State
    let isStale: Bool

    var body: some View {
        Text(isStale ? ChargeNowActivity.confirmed(state, zone: attributes.zone) : ChargeNowActivity.noTimeLimit)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Time since the box confirmed Charge now, counting up on its own.
private struct Elapsed: View {
    let state: ChargeNowActivity.State

    var body: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Tone.accent)
    }
}

private struct Bolt: View {
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        Image(systemName: "bolt.car.fill")
            .foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.accent))
    }
}

/// The one command here. It asks for the unlocked phone and runs in the
/// app, which ends this Live Activity when the box confirms.
private struct BackToPlan: View {
    let loadpointID: String

    var body: some View {
        Button(intent: BackToPlanIntent(loadpointID: loadpointID)) {
            Label(ChargeNowActivity.backToPlan, systemImage: "calendar")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Tone.accent)
    }
}
