import FTWKit
import SwiftUI

/// FTW Cloud in About: on or off, and the receipt once the copy is erased.
/// An owner changes it at the box over Noise; a viewer sees it.
struct CloudSettingsView: View {
    let app: AppModel
    @State private var consent = CloudConsent()

    var body: some View {
        List {
            if let site = app.site {
                switch CloudConsent.audience(site) {
                case .owner:
                    owner(site)
                case .ownerLater:
                    Section { Text(CloudWords.text("Your box can't use FTW Cloud yet.")) }
                case .viewer, .unknown:
                    Section {
                        Text(CloudWords.text(site.cloudOn ? "FTW Cloud is on for this home." : "FTW Cloud is off for this home."))
                    } footer: {
                        Text(CloudWords.text("Only the owner of this home can change this."))
                    }
                }
            }
            Section {
                Link(destination: Origin.privacyURL()) {
                    Label(CloudWords.text("Privacy policy"), systemImage: "hand.raised")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(CloudWords.text("FTW Cloud"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let site = app.site else { return }
            await consent.refresh(site)
        }
    }

    @ViewBuilder
    private func owner(_ site: SiteModel) -> some View {
        let box = consent.box
        let on = box?.on ?? site.cloudOn
        Section {
            Toggle(CloudWords.text("FTW Cloud"), isOn: Binding(get: { on }, set: { want in
                Task {
                    if want { await consent.turnOn(site) } else { await followErasure(site) }
                }
            }))
            .disabled(consent.working || box?.erasing == true)
            if on {
                Label(CloudWords.text(site.cloudStatus?.isOpen == true || box?.connected == true ? "Connected" : "Not connected"), systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Theme.fgDim)
            }
            if box?.erasing == true {
                Label(CloudWords.text("Erasing the copy"), systemImage: "hourglass")
            } else if !on, let at = box?.erasedAtMs {
                Label(CloudWords.format("Copy erased %@", AppWords.day(at, nowMs: Date().timeIntervalSince1970 * 1000, zone: .current)), systemImage: "checkmark.seal")
                    .foregroundStyle(Theme.fgDim)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(CloudWords.text("Turning it off erases the copy in FTW Cloud. Your box shows when it is gone."))
                if let help = consent.help { Text(help).foregroundStyle(Theme.importing) }
            }
        }
        if on {
            Section {
                Toggle(CloudWords.text("Contribute to statistics"), isOn: Binding(get: { box?.stats ?? false }, set: { want in
                    Task { await consent.setStats(want, site) }
                }))
                .disabled(consent.working)
            } footer: {
                Text(CloudWords.text("Hourly energy totals, without your name or address, help make FTW better. Off unless you turn it on."))
            }
        }
    }

    /// Off, then the receipt: the box has it once the service confirms the
    /// copy is gone, usually within seconds. Asked a few times after the
    /// tap, never on a timer of its own.
    private func followErasure(_ site: SiteModel) async {
        guard await consent.turnOff(site) else { return }
        for _ in 0..<5 where consent.box?.erasing == true {
            try? await Task.sleep(for: .seconds(2))
            await consent.refresh(site)
        }
    }
}
