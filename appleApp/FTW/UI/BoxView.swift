import CoreImage
import CoreImage.CIFilterBuiltins
import FTWKit
import SwiftUI

/// The box this phone is paired to: what it is, who else it trusts, what it
/// tells phones, the spare key, and leaving.
struct BoxView: View {
    let app: AppModel
    let home: HomeModels
    @State private var leaving = false

    private var site: SiteModel { home.site }
    private var stored: StoredSite? { site.siteId.flatMap { app.sites.get($0) } }

    var body: some View {
        Group {
            Title("Your FTW Box")
            if let stored {
                Text(SiteList.fingerprint(stored.boxStaticKey.byteArray))
                    .font(Theme.number(17))
                    .foregroundStyle(Theme.fgDim)
            }
            Card {
                Row("App version", "\(AppInfo.version) (\(AppInfo.buildNumber))", number: true)
                if let build = site.session.box?.build { Row("Software", build, number: true) }
                if let zone = Self.timeZone(site.session.box?.tz) { Row("Time zone", zone) }
                if let stored { Row("Paired", Clock.day(stored.addedAtMs)) }
                if let id = app.vault.deviceIDOnBox { Row("This phone", id, number: true) }
            }

            AccessSection(site: site, access: home.access)
            NotificationsSection(site: site, notify: home.notify)
            RestartSection(site: site, restart: home.restart)
            if let copy = app.sealedCopy {
                SealedCopySection(copy: copy)
            }
            signOut
        }
        .onAppear {
            home.access.activate()
            home.notify.activate()
            app.sealedCopy?.reload()
        }
        .onDisappear {
            home.access.deactivate()
            home.notify.deactivate()
        }
    }

    @ViewBuilder private var signOut: some View {
        Divider().overlay(Theme.line)
        if leaving {
            Text("Sign out on this phone?").font(.title3.weight(.semibold))
            Text("This phone stops showing your home and forgets its key. Nothing is removed from your box. It keeps running and keeps every reading.")
            if app.sealedCopy?.kept == true {
                Text("The sealed copy stays, so you can open this home again with your passkey. To remove it instead, turn off the sealed copy above before you sign out.")
            } else {
                Text("To come back, open the box's local dashboard and use Settings → FTW app → Show pairing code.")
            }
            Text("Signing out here does not remove this phone from your box. If you are handing the phone on, remove it there too: Settings, then FTW app\(app.vault.deviceIDOnBox.map { ", looking for \($0)" } ?? "").")
            Button("Sign out") { app.leave() }.buttonStyle(.danger)
            Button("Cancel") { leaving = false }.buttonStyle(.quiet)
        } else {
            Text("Sign out").font(.title3.weight(.semibold))
            Text("Clears this home from this phone. Your box and its readings are not touched.")
            Button("Sign out") { leaving = true }.buttonStyle(.outline)
        }
    }

    /// A box that says "local" means the zone it runs in, which is almost
    /// always the phone's own.
    static func timeZone(_ zone: String?) -> String? {
        guard let named = zone?.trimmingCharacters(in: .whitespaces), !named.isEmpty else { return nil }
        return named.lowercased() == "local" ? TimeZone.current.identifier : named
    }
}

private struct Row: View {
    let label: String
    let value: String
    var number = false

    init(_ label: String, _ value: String, number: Bool = false) {
        self.label = label
        self.value = value
        self.number = number
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.fgDim)
            Spacer()
            Text(value)
                .font(number ? Theme.number(14, weight: .regular) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: Who can see this home

private struct AccessSection: View {
    let site: SiteModel
    let access: AccessModel
    @State private var confirming: String?

    var body: some View {
        Divider().overlay(Theme.line)
        Text("Who can see this home").font(.title3.weight(.semibold))
        if !site.heardFromBox {
            Text("Reaching your box…")
        } else if !site.canConfigure {
            Text("You have view-only access. You can see this home's readings; changing anything, and who else can see it, belongs to its owner.")
        } else if !site.hasPassthrough {
            Text("Sharing needs newer software on your box.")
        } else {
            members
            invite
            if let error = access.error { Problem(error) }
        }
    }

    @ViewBuilder private var members: some View {
        if access.members.isEmpty {
            Hint(access.loading ? "Reading your box…" : access.loaded ? "No phones are paired with this box." : "The list has not come through yet. Still asking.")
        }
        ForEach(access.members) { member in
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.id).font(Theme.number(15))
                    Text("\(AccessModel.roleLabel(member.role)) · \(access.seen(member.lastSeenMs))\(member.isThisPhone ? " · this phone" : "")")
                        .font(.caption)
                        .foregroundStyle(Theme.fgDim)
                }
                Spacer()
                if member.isThisPhone {
                    Text("use Sign out").font(.caption).foregroundStyle(Theme.fgMuted)
                } else if member.role == Contract.roleOwner, access.owners <= 1 {
                    Text("last owner").font(.caption).foregroundStyle(Theme.fgMuted)
                } else if confirming == member.id {
                    Button("Remove") {
                        Task { if await access.revoke(member.id) { confirming = nil } }
                    }
                    .buttonStyle(.danger)
                    .fixedSize()
                    .disabled(access.busy == .revoking)
                    Button("Cancel") { confirming = nil }.buttonStyle(.quiet)
                } else {
                    Button("Remove") { confirming = member.id }.buttonStyle(.outline)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var invite: some View {
        if let invite = access.invite {
            Text("Let the person joining point their camera at this. It lets them see this home and nothing else, and it works once\(invite.expiresAtMs > 0 ? ", until \(Clock.time(invite.expiresAtMs))" : "").")
            // A square and never text: what is in it is everything it takes
            // to become a phone this house trusts.
            QRCodeView(text: invite.url)
                .frame(width: 240, height: 240)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Pairing code for this home")
            Button("Done") { access.dismissInvite() }.buttonStyle(.quiet)
        } else {
            Hint("A viewer sees your readings and can change nothing. Making an invitation cancels any pairing code already showing on your box.")
            Button(access.busy == .inviting ? "Asking your box" : "Invite someone to view") {
                Task { await access.inviteViewer() }
            }
            .buttonStyle(.outline)
            .disabled(access.busy == .inviting)
        }
    }
}

/// A QR drawn on the device, crisp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        } else {
            Hint("The code didn't draw. Open this screen again to draw it.")
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

// MARK: Notifications

private struct NotificationsSection: View {
    let site: SiteModel
    let notify: NotifyModel

    var body: some View {
        Divider().overlay(Theme.line)
        Text("Notifications").font(.title3.weight(.semibold))
        if !site.heardFromBox {
            Text("Reaching your box…")
        } else if !site.canConfigure {
            Text("Notifications are turned on by this home's owner.")
        } else if !site.hasPassthrough {
            Text("Notifications need newer software on your box.")
        } else if notify.oldBox {
            Text("Your box doesn't have that yet. It may be running older software.")
        } else {
            // The box reaches phones through web push today. This app has no
            // push channel of its own, and says so rather than offering a
            // switch that could not deliver.
            Text("This app does not receive notifications yet. Your box sends them to phones that turned them on in the FTW web app, and the choices below apply to every one of them.")
            if notify.boxEnabled {
                rules
            } else {
                Hint("No phone has turned notifications on for this box. Turn them on from the FTW web app on your phone.")
            }
            if let error = notify.error { Problem(error) }
        }
    }

    @ViewBuilder private var rules: some View {
        ForEach(NotifyModel.ruleKinds.filter { notify.availableKinds.contains($0) }, id: \.self) { kind in
            Toggle(NotifyModel.labels[kind] ?? kind, isOn: Binding(
                get: { notify.rules[kind] ?? false },
                set: { on in
                    var next = notify.rules
                    next[kind] = on
                    Task { await notify.save(next) }
                }
            ))
            .disabled(notify.busy != .none)
        }
        Hint("\(NotifyModel.labels["box.unreachable"] ?? "") is always on while notifications are on.")
        if notify.busy == .saving { Hint("Saving…") }
        Button(notify.busy == .testing ? "Asking your box…" : "Send a test") {
            Task { await notify.sendTest() }
        }
        .buttonStyle(.outline)
        .disabled(notify.busy != .none)
        if notify.testSent {
            Hint("Sent. It shows up on the phones your box can reach in a moment.")
        }
        if !notify.history.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notify.history) { row in
                    HStack {
                        Text(row.title).font(.callout)
                        Spacer()
                        Text(notify.when(row.atMs)).font(.caption).foregroundStyle(Theme.fgMuted)
                    }
                }
            }
        }
    }
}

// MARK: Restart

private struct RestartSection: View {
    let site: SiteModel
    let restart: RestartModel

    var body: some View {
        if restart.canAsk {
            Divider().overlay(Theme.line)
            switch restart.stage {
            case .confirming:
                Text("Restart this box?").font(.title3.weight(.semibold))
                Text("The software restarts. Devices keep running on their own until it comes back, usually within a minute. This phone reconnects by itself.")
                Button("Restart now") { Task { await restart.restart() } }.buttonStyle(.danger)
                Button("Cancel") { restart.stage = .idle }.buttonStyle(.quiet)
            case .restarting:
                Text("Restarting").font(.title3.weight(.semibold))
                Text("Your box is coming back on its own. This usually takes a minute.")
            case .idle:
                Text("Restart").font(.title3.weight(.semibold))
                Text("Restarts the software on this box. Use it when a device is stuck and will not come back on its own.")
                Button("Restart this box") { restart.stage = .confirming }.buttonStyle(.outline)
            }
            if let error = restart.error { Problem(error) }
        }
    }
}

// MARK: The spare key

private struct SealedCopySection: View {
    let copy: SealedCopyModel

    var body: some View {
        Divider().overlay(Theme.line)
        Text("If you lose this phone").font(.title3.weight(.semibold))
        if copy.kept {
            Text("Sourceful holds a sealed copy it cannot open, with an opaque id and nothing beside it. A new phone gets this home back with your passkey alone.")
            Text("Which also means your passkey is enough to open this home, on any device that can pass Face ID for it.")
            Button(copy.stage == .working ? "Removing the copy" : "Remove the copy") { Task { await copy.set(false) } }
                .buttonStyle(.outline)
                .disabled(copy.stage == .working)
        } else {
            Text("No sealed recovery copy is saved for this home right now. FTW normally makes one when you pair on a phone that supports passkey recovery. Sourceful can hold that copy without opening it, with an opaque id and nothing beside it, so a new phone gets this home back with your passkey.")
            Text("The cost: your passkey is then enough to open this home, on any device that can pass Face ID for it. Nothing is saved unless you ask.")
            Button(copy.stage == .working ? "Saving a sealed copy" : "Keep a sealed copy") { Task { await copy.set(true) } }
                .buttonStyle(.outline)
                .disabled(copy.stage == .working)
        }
        if copy.stage == .failed, let problem = copy.problem { Problem(problem) }
    }
}

// MARK: The demo's Box screen

struct DemoBoxView: View {
    let site: SiteModel
    let exit: () -> Void

    var body: some View {
        Title("Demo home")
        Text("Simulated FTW box").font(Theme.number(15)).foregroundStyle(Theme.fgDim)
        Text("This is the same app and protocol as a connected home. The readings and changes stay in this demo and reset when you leave.")
        Card {
            Row("App version", "\(AppInfo.version) (\(AppInfo.buildNumber))", number: true)
            if let build = site.session.box?.build { Row("Software", build, number: true) }
            if let zone = BoxView.timeZone(site.session.box?.tz) { Row("Time zone", zone) }
            Row("Data", "Simulated")
        }
        Divider().overlay(Theme.line)
        Text("Access").font(.title3.weight(.semibold))
        Text("On a connected home, this screen lists owner and viewer phones. An owner can invite a viewer or remove access.")
        Divider().overlay(Theme.line)
        Text("Notifications").font(.title3.weight(.semibold))
        Text("A connected home can tell its phones about useful events, such as a finished EV charge, a device that stops answering, or a box that went quiet.")
        Divider().overlay(Theme.line)
        Text("Passkey recovery").font(.title3.weight(.semibold))
        Text("A real home can keep a sealed recovery copy for its passkey. Sourceful cannot open it, and the owner can remove it here.")
        Button("Exit demo and connect your box", action: exit).buttonStyle(.primary)
    }
}
