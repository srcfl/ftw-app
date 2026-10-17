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

    func body(content: Content) -> some View {
        Group {
            if app.cloudPaused {
                ContentUnavailableView {
                    Label(CloudWords.text("FTW Cloud"), systemImage: "cloud.slash")
                } description: {
                    Text(CloudWords.text("This phone has stopped using FTW Cloud. Your box keeps working locally."))
                } actions: {
                    Button(CloudWords.text("Review Cloud terms")) { consent.review(); app.resumeCloud() }
                }
            } else { content }
        }
            .sheet(isPresented: Binding(get: { !app.cloudPaused && !app.needsPairing && consent.shouldAsk(app.site) }, set: { _ in })) {
                CloudConsentView(app: app, consent: consent)
                    .presentationDragIndicator(.hidden)
                    .tint(Theme.accent)
            }
    }
}
