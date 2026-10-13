import FTWKit
import SwiftUI

extension View {
    /// The FTW Cloud consent, once, over a real home, and the owner's grant
    /// at the box once the box can take it. RootView's one line.
    func cloudConsent(_ app: AppModel) -> some View {
        modifier(CloudGate(app: app))
    }
}

private struct CloudGate: ViewModifier {
    let app: AppModel
    @State private var consent = CloudConsent()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { !app.needsPairing && consent.shouldAsk(app.site) }, set: { _ in })) {
                CloudConsentView(app: app, consent: consent)
                    .presentationDragIndicator(.hidden)
                    .tint(Theme.accent)
            }
            // When the box answers, an owner who agreed turns FTW Cloud on
            // there, once per home.
            .task(id: ensureKey) {
                guard let site = app.site else { return }
                await consent.ensure(site)
            }
    }

    private var ensureKey: String {
        guard let site = app.site else { return "" }
        return "\(site.siteId ?? "")-\(site.heardFromBox)-\(site.cloudOn)-\(consent.answered)"
    }
}
