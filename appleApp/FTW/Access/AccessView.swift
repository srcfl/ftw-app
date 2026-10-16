import FTWKit
import SwiftUI

/// Who may reach this home other than its phones and watches: the
/// assistants and Sourceful support the owner let in, what they ask for,
/// and what they did. The box decides; this is what it said, and the
/// owner's word back.
struct AccessView: View {
    let app: AppModel
    let access: AccessModel

    var body: some View {
        List {
            if !access.pending.isEmpty {
                Section(AccessWords.text("Waiting for you")) {
                    ForEach(access.pending) { req in
                        NavigationLink { RequestView(access: access, request: req) } label: { RequestLine(access: access, request: req) }
                            .accessibilityIdentifier("access.request.\(req.reqId)")
                    }
                }
            }

            Section {
                ForEach(access.assistants) { row in
                    NavigationLink { GrantView(app: app, access: access, id: row.id) } label: { GrantLine(access: access, row: row) }
                        .swipeActions { remove(row) }
                        .accessibilityIdentifier("access.grant.\(row.id)")
                }
                if access.list != nil, access.assistants.isEmpty {
                    Text(AccessWords.text("No assistant can reach your home."))
                        .foregroundStyle(Theme.ink2)
                }
                NavigationLink {
                    OfferFlowView(app: app, flow: OfferFlow(link: nil, lookup: app.offerLookup, keys: app.offerKeys))
                } label: {
                    Label(AccessWords.text("Add an assistant"), systemImage: "plus")
                }
                .accessibilityIdentifier("access.add")
            } header: {
                Text(AccessWords.text("Assistants"))
            } footer: {
                Text(AccessWords.text("Assistants such as Claude or ChatGPT reach your home through FTW Cloud, with what you let them. Your box checks every call."))
            }

            Section(AccessWords.text("Sourceful support")) {
                ForEach(access.support) { row in
                    NavigationLink { GrantView(app: app, access: access, id: row.id) } label: { GrantLine(access: access, row: row) }
                        .swipeActions { remove(row) }
                }
                NavigationLink { GetHelpView(app: app, access: access) } label: {
                    Label(AccessWords.text("Get help"), systemImage: "lifepreserver")
                }
                .accessibilityIdentifier("access.help")
            }

            Section {
                NavigationLink { AuditView(access: access) } label: {
                    Label(AccessWords.text("Activity"), systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("access.activity")
            } footer: {
                KeyFooter(access: access)
            }
        }
        .redacted(reason: access.list == nil ? .placeholder : [])
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(AccessWords.text("Access"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Theme.spring, value: access.list)
        .task { await access.refresh() }
        .refreshable { await access.refresh() }
    }

    /// Removing is one tap: no Face ID and no question, since it is always
    /// safe.
    private func remove(_ row: AgentRow) -> some View {
        Button(role: .destructive) {
            Task { await access.revoke(row) }
        } label: {
            Label(AccessWords.text("Remove access"), systemImage: "xmark.circle")
        }
    }
}

/// One grant in the list: its name, where it lives, what it may do, when it
/// ends and when it last called.
struct GrantLine: View {
    let access: AccessModel
    let row: AgentRow

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccessWords.name(row)).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if access.working == row.id { ProgressView().controlSize(.small) }
            }
            Text(row.isSupport ? AccessWords.format("Ticket %@", row.principal.ticket) : AccessWords.host(row))
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
            Text("\(AccessWords.summary(row.scopes)) · \(AccessWords.until(row.expiresAtMs, nowMs: now)) · \(AccessWords.lastUsed(row.lastSeenMs, nowMs: now))")
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A request in the list: who asks for what, and until when it waits.
struct RequestLine: View {
    let access: AccessModel
    let request: AgentRequest

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AccessWords.format("%@ asks to", access.agentName(request.agent)))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                Text(AccessWords.op(request.op)).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(AccessWords.format("Waits %@", AppWords.day(Double(request.expiresAtMs), nowMs: now, zone: .current)))
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// How this phone approves: Face ID, a key yet to be made, or a key Face ID
/// voided.
struct KeyFooter: View {
    let access: AccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AccessWords.format(access.boxHasKey ? "Approvals on this phone use %@." : "This phone makes its approval key the first time you approve, under the same %@.", AccessWords.biometry))
            if let help = access.help {
                Text(help).foregroundStyle(Theme.alarm)
            }
        }
    }
}
