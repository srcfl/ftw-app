import FTWKit
import SwiftUI

/// One grant: who, what it may do, until when, and when it last called.
/// Any change is signed with Face ID, narrowing included; removing it is
/// one tap.
struct GrantView: View {
    let app: AppModel
    let access: AccessModel
    let id: String
    @State private var scopes: Set<String> = []
    @State private var control = false
    @State private var lengthMs: Int64 = 0
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let row = access.row(id) {
            form(row)
                .onAppear { load(row) }
                .onChange(of: row.epoch) { load(row) }
        } else {
            // Removed, here or elsewhere.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func load(_ row: AgentRow) {
        scopes = Set(row.scopes).subtracting(AccessWire.controlScopes)
        control = row.hasControl
        lengthMs = 0
        loaded = true
    }

    private func form(_ row: AgentRow) -> some View {
        let now = Date().timeIntervalSince1970 * 1000
        let reads = (Contract.agentRoleScopes[row.role] ?? []).filter { !AccessWire.controlScopes.contains($0) }
        let lengths = Grant.lengths(role: row.role)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AccessWords.name(row)).font(.title2.weight(.bold))
                    let place = row.isSupport ? AccessWords.format("Ticket %@", row.principal.ticket) : access.host(row)
                    if !place.isEmpty {
                        Text(place)
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                    }
                    if let verified = access.verified(row), !row.isSupport {
                        Label(AccessWords.text(verified ? "Verified by FTW Cloud" : "Not verified"),
                              systemImage: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(verified ? Theme.ink : Theme.alarm)
                    }
                    if let problem = access.problem(row) {
                        Text(problem).font(.callout).foregroundStyle(Theme.ink2)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent(AccessWords.text("Ends"), value: AccessWords.ends(row.expiresAtMs, nowMs: now))
                    .accessibilityIdentifier("grant.ends")
                LabeledContent(AccessWords.text("Last used"), value: AccessWords.lastCall(row.lastSeenMs, nowMs: now))
                LabeledContent(AccessWords.text("Approved"), value: AccessWords.approvedWhere(row, me: access.signedFor.deviceID))
            }

            Section(AccessWords.text("May")) {
                ForEach(AccessWords.ordered(reads), id: \.self) { scope in
                    Toggle(AccessWords.scope(scope), isOn: Binding(
                        get: { scopes.contains(scope) },
                        set: { on in if on { scopes.insert(scope) } else { scopes.remove(scope) } }
                    ))
                    .tint(Theme.live)
                }
            }

            if row.role != Contract.roleRelease {
                Section {
                    Toggle(AccessWords.text("Control"), isOn: $control).tint(Theme.live)
                } footer: {
                    let g = grant(row)
                    Text(control ? AccessWords.control(g.caps, scopes: g.scopes) : AccessWords.text("Off: it reads and changes nothing."))
                }
            }

            Section {
                Picker(AccessWords.text("Renew for"), selection: $lengthMs) {
                    Text(AccessWords.until(row.expiresAtMs, nowMs: now)).tag(Int64(0))
                    ForEach(lengths, id: \.self) { Text(AccessWords.length($0)).tag($0) }
                }
            } footer: {
                if let help = access.help { Text(help).foregroundStyle(Theme.alarm) }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        if await access.revoke(row) { dismiss() }
                    }
                } label: {
                    Label(AccessWords.text("Remove access"), systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("grant.remove")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(AccessWords.name(row))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if loaded, changed(row) {
                Button {
                    Task { await access.widen(row, to: grant(row)) }
                } label: {
                    HStack(spacing: 8) {
                        if access.working == row.id { ProgressView().tint(Theme.onAccent) } else { Image(systemName: Biometry.symbol) }
                        Text(AccessWords.format("Save with %@", AccessWords.biometry))
                    }
                }
                .buttonStyle(FTWButtonStyle(kind: .primary))
                .disabled(scopes.isEmpty || access.working != nil)
                .padding(16)
                .background(Theme.surface)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("grant.save")
            }
        }
        .animation(Theme.spring, value: changed(row))
    }

    /// The whole new grant. Control turned on asks for the ops the box
    /// opens to agents, within FTW Cloud's proposed caps; a narrower one
    /// keeps the row's own.
    private func grant(_ row: AgentRow) -> Grant {
        var all = scopes
        var ops = row.ops
        var caps = row.caps
        if control {
            all.formUnion(AccessWire.controlScopes)
            if !row.hasControl {
                ops = Contract.agentOps.keys.filter { AccessWire.controlScopes.contains(Contract.agentOps[$0]!) }
                caps = Caps(holdS: AccessWire.holdSRange.upperBound, maxW: 11_000, perMin: AccessWire.perMinDefault)
            }
        } else {
            ops = []
            caps = Caps(perMin: row.caps.perMin)
        }
        // Unrenewed, the end stays where it is.
        let remaining = row.expiresAtMs - Int64(Date().timeIntervalSince1970 * 1000) + Approval.skewMs
        return Grant(scopes: Array(all), ops: ops, caps: caps, lengthMs: lengthMs == 0 ? remaining : lengthMs)
    }

    private func changed(_ row: AgentRow) -> Bool {
        scopes != Set(row.scopes).subtracting(AccessWire.controlScopes) || control != row.hasControl || lengthMs != 0
    }
}
