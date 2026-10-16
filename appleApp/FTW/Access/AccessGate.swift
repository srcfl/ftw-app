import FTWKit
import SwiftUI

extension View {
    /// A link from an assistant's consent page opens its sheet over the
    /// home, once a home is open to grant from. RootView's one line.
    func accessLinks(_ app: AppModel) -> some View {
        modifier(AccessGate(app: app))
    }
}

private struct AccessGate: ViewModifier {
    let app: AppModel
    /// FTW Cloud's one screen at first start goes first: one sheet at a
    /// time, and a link waits for it.
    @AppStorage(CloudConsent.answeredKey) private var consented: String?

    private var cloudScreenUp: Bool {
        guard let site = app.site, !site.isDemo, site.siteId != nil else { return false }
        return consented != CloudConsent.policy
    }

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { app.needsPairing || app.home?.access == nil || cloudScreenUp ? nil : app.accessLink },
            set: { if $0 == nil { app.accessLink = nil } }
        )) { link in
            OfferSheet(app: app, flow: OfferFlow(link: link, lookup: app.offerLookup, keys: app.offerKeys))
                .tint(Theme.accent)
        }
    }
}

/// The Access rows in Settings: who may reach the home, with what waits
/// for the owner, and Get help. Only an owner whose box takes agents sees
/// them.
struct AccessSettingsSection: View {
    let app: AppModel
    let access: AccessModel

    var body: some View {
        if access.available {
            Section(AccessWords.text("Access")) {
                NavigationLink { AccessView(app: app, access: access) } label: {
                    LabeledContent {
                        if !access.pending.isEmpty {
                            Text(AccessWords.format("%@ waiting", String(access.pending.count)))
                                .foregroundStyle(Theme.ink)
                                .contentTransition(.numericText())
                        }
                    } label: {
                        Label(AccessWords.text("Assistants and support"), systemImage: "person.badge.key")
                    }
                }
                .accessibilityIdentifier("settings.access")
                NavigationLink { GetHelpView(app: app, access: access) } label: {
                    Label(AccessWords.text("Get help"), systemImage: "lifepreserver")
                }
                .accessibilityIdentifier("settings.help")
            }
            .task { await access.refresh() }
        }
    }
}
