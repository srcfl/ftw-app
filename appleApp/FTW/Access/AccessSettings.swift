import FTWKit
import SwiftUI

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
