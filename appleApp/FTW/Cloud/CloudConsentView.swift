import FTWKit
import SwiftUI

/// The one screen, at first start: the app uses FTW Cloud, and statistics
/// are a separate choice, off until ticked. An owner's phone turns FTW Cloud
/// on at the box when the person goes on; a viewer is told to ask the owner.
struct CloudConsentView: View {
    let app: AppModel
    @Bindable var consent: CloudConsent

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
                    Text(CloudWords.text("Your box still decides. Commands go straight to it, never through FTW Cloud."))
                        .foregroundStyle(Theme.fgDim)
                }
                .padding(.vertical, 4)
            }

            switch audience {
            case .viewer:
                Section {
                    Label(CloudWords.text("Ask the owner of this home to turn on FTW Cloud."), systemImage: "person.crop.circle.badge.questionmark")
                }
            case .owner, .ownerLater, .unknown:
                Section {
                    Toggle(CloudWords.text("Contribute to statistics"), isOn: $consent.contributeStats)
                        .tint(Theme.live)
                } footer: {
                    Text(CloudWords.text("Hourly energy totals, without your name or address, help make FTW better. Off unless you turn it on."))
                }
                if audience == .ownerLater {
                    Section {
                        Label(CloudWords.text("Your box turns on FTW Cloud after its next update."), systemImage: "arrow.down.circle")
                    }
                }
            }

            Section {
                Link(destination: Origin.privacyURL()) {
                    Label(CloudWords.text("Privacy policy"), systemImage: "hand.raised")
                }
            } footer: {
                Text(CloudWords.text("You can turn FTW Cloud off in About."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .safeAreaInset(edge: .bottom) {
            Button(CloudWords.text("Continue")) {
                Task { await consent.accept(app.site) }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .padding(16)
            .background(Theme.surface)
        }
        .animation(Theme.spring, value: audience)
        .sensoryFeedback(.success, trigger: consent.answered)
        .interactiveDismissDisabled()
    }
}
