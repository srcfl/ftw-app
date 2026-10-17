import FTWKit
import SwiftUI

extension View {
    /// The current Cloud terms, accepted for each real home before its owner
    /// grants the new scope. Opening a screen never creates a grant.
    func cloudConsent(_ app: AppModel) -> some View {
        modifier(CloudGate(app: app))
    }
}

private struct CloudGate: ViewModifier {
    let app: AppModel
    @State private var consent = CloudConsent()
    @State private var reviewingPaused = false

    func body(content: Content) -> some View {
        Group {
            if app.cloudPaused && !app.needsPairing {
                ContentUnavailableView {
                    Label(CloudWords.text("FTW Cloud"), systemImage: "cloud.slash")
                } description: {
                    Text(CloudWords.text("This phone has stopped using FTW Cloud. Your box keeps working locally."))
                } actions: {
                    Button(CloudWords.text("Review Cloud terms")) { reviewingPaused = true }
                    Menu(CloudWords.text("Homes")) {
                        ForEach(app.homes) { home in
                            Button(HomeName.title(home.label)) { app.open(home.siteId) }
                        }
                        Button(CloudWords.text("Pair a home")) { app.recovering = true }
                    }
                }
            } else { content }
        }
            .sheet(isPresented: Binding(get: { reviewingPaused || (!app.cloudPaused && !app.needsPairing && consent.shouldAsk(app.site)) }, set: { shown in if !shown { reviewingPaused=false } })) {
                CloudConsentView(app: app, consent: consent, onPausedChoice: { reviewingPaused=false })
                    .presentationDragIndicator(.hidden)
                    .tint(Theme.accent)
            }
            .task(id: "\(app.site?.siteId ?? "")-\(app.site?.heardFromBox ?? false)-\(app.cloudPaused)") {
                guard !app.cloudPaused, let site=app.site else { return }
                await consent.finishPendingAcceptance(site)
            }
    }
}
