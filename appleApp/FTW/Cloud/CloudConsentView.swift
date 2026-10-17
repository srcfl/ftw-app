import FTWKit
import SwiftUI

/// Current Cloud terms at first start. Statistics come with Cloud;
/// an owner grants the scope, while a viewer accepts it for this phone.
struct CloudConsentView: View {
    let app: AppModel
    @Bindable var consent: CloudConsent
    @Environment(\.dynamicTypeSize) private var typeSize

    private var audience: CloudConsent.Audience {
        app.site.map(CloudConsent.audience) ?? .unknown
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "cloud.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: consent.answered)
                        .accessibilityHidden(true)
                    Text(CloudWords.text("The FTW app uses FTW Cloud"))
                        .font(.title2.weight(.bold))
                    Text(CloudWords.text("FTW Cloud is part of the service. It keeps a copy of your home, signed by your box, so the app opens at once and stays up to date."))
                    Text(CloudWords.text("Your box still decides. Commands stay encrypted between this phone and your box."))
                        .foregroundStyle(Theme.fgDim)
                }
                .padding(.vertical, 4)
            }

            Section {
                Text(CloudWords.text(CloudConsent.included))
                Text(CloudWords.text(CloudConsent.statisticsDetails))
                Text(CloudWords.text(CloudConsent.statisticsPrivacy))
                if !consent.statisticsReady { Text(CloudWords.text(CloudConsent.statisticsWaiting)) }
                if let help = consent.help { Text(help).foregroundStyle(Theme.alarm) }
            }
            if audience == .viewer {
                Section {
                    Label(CloudWords.text("Ask the owner of this home to turn on FTW Cloud."), systemImage: "person.crop.circle.badge.questionmark")
                }
            } else if audience == .ownerLater {
                Section {
                    Label(CloudWords.text("Update your box before accepting the new Cloud terms."), systemImage: "arrow.down.circle")
                }
            }

            Section {
                Link(destination: Origin.privacyURL()) {
                    Label(CloudWords.text("Privacy policy"), systemImage: "hand.raised")
                }
            } footer: {
                Text(CloudWords.text("You can turn FTW Cloud off in About."))
            }
            if typeSize.isAccessibilitySize { Section { actions } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .safeAreaInset(edge: .bottom) {
            if !typeSize.isAccessibilitySize {
                actions.padding(16).background(Theme.surface)
            }
        }
        .task(id: audience) {
            if let site = app.site, audience == .owner { await consent.refreshStatisticsPolicy(site) }
        }
        .animation(Theme.spring, value: audience)
        .sensoryFeedback(.success, trigger: consent.answered)
        .interactiveDismissDisabled()
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(CloudWords.text("Accept Cloud terms")) {
                Task { await consent.accept(app.site) }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .disabled(consent.working || audience == .unknown || audience == .ownerLater || (audience == .owner && !consent.policyAvailable))
            Button(CloudWords.text("Use the box locally")) { app.pauseCloud() }
                .buttonStyle(FTWButtonStyle(kind: .quiet))
        }
    }

}
