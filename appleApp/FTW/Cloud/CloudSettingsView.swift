import FTWKit
import SwiftUI

/// FTW Cloud in About: current terms and one choice for the whole service.
/// An owner changes it at the box over Noise; a viewer sees it.
struct CloudSettingsView: View {
    let app: AppModel
    @State private var consent = CloudConsent()
    @State private var stopping = false

    var body: some View {
        List {
            if app.isDemo {
                Section { Text(CloudWords.text("Demo: no reports leave this phone.")) }
            }
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
        .confirmationDialog(CloudWords.text("Turn FTW Cloud off?"), isPresented: $stopping, titleVisibility: .visible) {
            Button(CloudWords.text("Turn off"), role: .destructive) {
                Task { if let site = app.site { _ = await consent.turnOff(site) }; app.pauseCloud() }
            }
            Button(CloudWords.text("Cancel"), role: .cancel) { }
        } message: {
            Text(CloudWords.text("Turning FTW Cloud off stops remote access for phones and assistants. The box keeps working locally. You may need to pair phones again later. Check the local box for the deletion receipt."))
        }
        .task(id: app.site.map(CloudConsent.audience)) {
            guard let site = app.site, CloudConsent.audience(site) == .owner else { return }
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
                    if want { await consent.turnOn(site) } else { stopping = true }
                }
            }))
            .tint(Theme.live)
            .disabled(consent.working || box?.erasing == true)
            if on {
                Label {
                    // The transport's own name, not translated: QUIC, or the
                    // WebSocket where UDP does not get through.
                    let state = Text(CloudWords.text(site.cloudStatus?.isOpen == true || box?.connected == true ? "Connected" : "Not connected"))
                    let transport = Text(site.cloudTransport.map { " · \(Self.transportName($0))" } ?? "").font(Theme.mono(.footnote))
                    Text("\(state)\(transport)")
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
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
                Text(CloudWords.text("Turning it off ends remote access and requests deletion. Check the local box for the receipt."))
                if let help = consent.help { Text(help).foregroundStyle(Theme.alarm) }
            }
        }
        if on {
            Section {
                Label(CloudWords.text("Statistics are included with FTW Cloud"), systemImage: "chart.bar")
                if box?.termsAccepted != true {
                    Button(CloudWords.text("Accept Cloud terms")) { Task { await consent.accept(site) } }
                        .disabled(consent.working || !consent.policyAvailable)
                }
                Text(CloudWords.text(CloudConsent.included))
                Text(CloudWords.text(CloudConsent.statisticsDetails))
                Text(CloudWords.text(CloudConsent.statisticsPrivacy))
                if !consent.statisticsReady { Text(CloudWords.text(CloudConsent.statisticsWaiting)) }
            }
        }
    }

    /// The registry's transport names, as people write them.
    static func transportName(_ transport: String) -> String {
        transport == Contract.transportQUIC ? "QUIC" : "WebSocket"
    }

}
