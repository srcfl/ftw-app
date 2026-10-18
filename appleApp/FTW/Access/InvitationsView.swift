import FTWKit
import SwiftUI

struct InvitationsView: View {
    let app: AppModel
    let access: AccessModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    NewInvitationView(app: app, access: access)
                } label: {
                    Label(AccessWords.text("Create an invitation"), systemImage: "plus")
                }
            } footer: {
                Text(
                    AccessWords.text(
                        "Share a code with someone who will use their own assistant. The first person who uses it gets a separate connection you can remove."
                    ))
            }
            ForEach(access.invitations) { row in
                Section {
                    Text(AccessWords.clean(row.label.isEmpty ? AccessWords.text("Guest") : row.label)).font(
                        .headline)
                    Text(AccessWords.summary(row.scopes)).font(.footnote).foregroundStyle(Theme.ink2)
                    Text(
                        AccessWords.text(
                            row.state == "pending"
                                ? (row.clockUnavailable ? "Waiting for the box's clock" : "Waiting to be used")
                                : row.state == "claimed" ? "Access is given" : "Invitation ended"))
                    LabeledContent(AccessWords.text("Use before"), value: when(row.claimUntilMs))
                    LabeledContent(AccessWords.text("Access ends"), value: when(row.expiresAtMs))
                    if row.state == "pending" {
                        Text(
                            AccessWords.text(
                                "The code cannot be shown again. Cancel this invitation and create a new one if needed."
                            )
                        ).font(.footnote).foregroundStyle(Theme.ink2)
                        Button(AccessWords.text("Cancel invitation"), role: .destructive) {
                            Task { _ = await access.cancelInvitation(row) }
                        }
                    } else if row.state == "claimed", access.row(row.agentID) != nil {
                        NavigationLink {
                            GrantView(app: app, access: access, id: row.agentID)
                        } label: {
                            Label(AccessWords.text("View or remove access"), systemImage: "person.badge.key")
                        }
                    }
                }
            }
            if let help = access.help { Section { Text(help).foregroundStyle(Theme.ink2) } }
        }
        .navigationTitle(AccessWords.text("Shared access"))
        .task {
            await access.refreshInvitations()
            await access.refresh()
        }
        .refreshable {
            await access.refreshInvitations()
            await access.refresh()
        }
    }
}

private func when(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
}

struct NewInvitationView: View {
    let app: AppModel
    let access: AccessModel
    @State private var draft = InvitationDraft()
    @State private var label = ""
    @State private var scopes = Set(
        (Contract.agentRoleScopes[AccessWire.roleAgent] ?? []).filter {
            !AccessWire.controlScopes.contains($0) && $0 != AccessWire.scopeSetup
        })
    @State private var setup = false
    @State private var control = false
    @State private var lengthMs: Int64 = 7 * 86_400_000
    @State private var power: Double = 11_000
    @State private var hold: Double = 900
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            if let receipt = draft.receipt {
                Section(
                    AccessWords.text(receipt.state == "pending" ? "Invitation code" : "Invitation ended")
                ) {
                    if let code = access.invitationCode(draft) {
                        Text(code).font(.system(.largeTitle, design: .monospaced)).textSelection(.enabled)
                        ShareLink(item: code) {
                            Label(AccessWords.text("Share code"), systemImage: "square.and.arrow.up")
                        }
                        Text(
                            AccessWords.text(
                                "They connect FTW in their assistant, choose ‘I have an invitation code’ on the FTW connection page and paste it. The box must be online when they use it. Anyone with the unused code can claim these rights."
                            ))
                    } else if receipt.state == "pending", draft.alias == nil {
                        Text(
                            AccessWords.text("Waiting for the box to publish the code. Keep this page open and retry the same invitation."))
                        Button(AccessWords.text("Get the six-character code")) { Task { await access.publishInvitation(draft) } }
                            .disabled(access.working != nil)
                    } else {
                        Text(
                            AccessWords.text(
                                receipt.state == "claimed"
                                    ? "Access is already given. Open Shared access to remove its connection."
                                    : receipt.state == "pending"
                                        ? "This code has ended. Check status before creating a new invitation."
                                        : "This invitation has ended."))
                    }
                    if receipt.state == "pending" {
                        Button(AccessWords.text("Check status and code")) { Task { await checkStatus() } }
                            .disabled(access.working != nil)
                        if let help = access.help { Text(help).font(.footnote).foregroundStyle(Theme.ink2) }
                    }
                    LabeledContent(AccessWords.text("Use before"), value: when(draft.alias?.expiresAtMs ?? receipt.claimUntilMs))
                    LabeledContent(AccessWords.text("Access ends"), value: when(receipt.expiresAtMs))
                }
            } else {
                Section {
                    TextField(AccessWords.text("Who is this for?"), text: $label)
                    ForEach(
                        Approval.sorted(Contract.agentRoleScopes[AccessWire.roleAgent] ?? []).filter {
                            !AccessWire.controlScopes.contains($0) && $0 != AccessWire.scopeSetup
                        }, id: \.self
                    ) { scope in
                        Toggle(
                            AccessWords.scope(scope),
                            isOn: Binding(
                                get: { scopes.contains(scope) },
                                set: { if $0 { scopes.insert(scope) } else { scopes.remove(scope) } }))
                    }
                    Toggle(AccessWords.text("Allow setup"), isOn: $setup)
                    if setup {
                        Text(
                            AccessWords.text(
                                "Setup can save equipment and electrical settings. Review and confirm the exact draft before saving and confirm any restart separately."
                            )
                        ).font(.footnote)
                    }
                    Toggle(AccessWords.text("Also let it control"), isOn: $control)
                    if control {
                        ForEach(Approval.sorted(Contract.agentOps.keys), id: \.self) { op in
                            Text(AccessWords.op(op)).font(.footnote)
                        }
                        LabeledContent(AccessWords.text("Power limit (W)")) {
                            TextField("11000", value: $power, format: .number).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent(AccessWords.text("Hold limit (seconds)")) {
                            TextField("900", value: $hold, format: .number).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Picker(AccessWords.text("Access lasts"), selection: $lengthMs) {
                        ForEach(access.invitationLengths, id: \.self) { length in
                            Text(AccessWords.length(length)).tag(length)
                        }
                    }
                    Text(
                        AccessWords.text(
                            "The six-character code works once and ends within ten minutes. Access lasts as long as you choose above."))
                } footer: {
                    Text(
                        AccessWords.text(
                            "The label does not check the recipient's identity. Technical backups can contain saved credentials. The code appears only while this page stays open."
                        ))
                }
                .disabled(draft.request != nil)
                if draft.request != nil {
                    Section {
                        Text(
                            AccessWords.text(
                                "Creation is not confirmed. Retry sends the exact same invitation. The Shared access list can show whether it already exists."
                            ))
                    }
                }
                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        if access.working == "invitation" {
                            ProgressView()
                        } else {
                            Text(
                                draft.request == nil
                                    ? AccessWords.format("Create code with %@", AccessWords.biometry)
                                    : AccessWords.text("Retry the same invitation"))
                        }
                    }.disabled(
                        (app.cloudHome == nil && !app.isDemo) || access.working != nil
                            || scopes.isEmpty && !setup && !control
                            || control
                                && (!power.isFinite || !hold.isFinite || power < 1 || power > 100_000 || hold < 60
                                    || hold > 1800)
                    )
                    if app.cloudHome == nil && !app.isDemo {
                        Text(
                            AccessWords.text("Wait for the box to connect to FTW Cloud before sharing access."))
                    }
                    if let help = access.help { Text(help).foregroundStyle(Theme.ink2) }
                }
            }
        }
        .navigationTitle(AccessWords.text("New invitation"))
        .task {
            await access.refresh()
            keepLengthValid()
            await checkStatus()
        }
        .onChange(of: access.invitationLengths) { _, _ in keepLengthValid() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await checkStatus() } } }
    }

    private func keepLengthValid() {
        guard draft.request == nil, !access.invitationLengths.contains(lengthMs) else { return }
        lengthMs = access.invitationLengths.last(where: { $0 <= 7 * 86_400_000 })
            ?? access.invitationLengths.first ?? 7 * 86_400_000
    }

    private func checkStatus() async {
        guard draft.receipt != nil else { return }
        await access.refreshInvitations()
        if let row = access.invitations.first(where: { $0.id == draft.id }) { draft.receipt = row }
        if draft.receipt?.state == "pending" { await access.publishInvitation(draft) }
    }

    private func create() async {
        guard let home = app.cloudHome ?? (app.isDemo ? "abcdefghijklmnopqrstuvwx23" : nil) else {
            return
        }
        var allowed = scopes
        if setup { allowed.insert(AccessWire.scopeSetup) }
        if control { allowed.formUnion(AccessWire.controlScopes) }
        let ops = Approval.sorted(
            Contract.agentOps.keys.filter { allowed.contains(Contract.agentOps[$0] ?? "") })
        let caps = Caps(holdS: control ? UInt64(hold) : 0, maxW: control ? UInt64(power) : 0, perMin: 6)
        let grant = Grant(scopes: Array(allowed), ops: ops, caps: caps, lengthMs: lengthMs)
        var name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 128 { name.removeLast() }
        _ = await access.createInvitation(
            draft, home: home, label: name, grant: grant, claimSeconds: 600)
        keepLengthValid()
    }
}
